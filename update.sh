#!/bin/bash

set -euo pipefail  # エラー・未定義変数・パイプライン失敗で即終了

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Error handling
cleanup_on_error() {
    log_error "Script failed. Cleaning up temporary files..."
    rm -f ./${listFileNameA} ./${listFileNameB} ${listFileNameTemp} 2>/dev/null || true
}

trap cleanup_on_error ERR

if [[ "$#" != "4" ]]; then
    log_error "Invalid number of arguments"
    echo "$0 [bucketName] [remoteSrcDir] [remoteDestDir] [controllDir]";
    exit 1
fi

bucketName=$1
remoteSrcDir=$2
remoteDestDir=$3
controllDir=$4

log_info "Starting script with parameters:"
log_info "  Bucket: $bucketName"
log_info "  Source Dir: $remoteSrcDir"
log_info "  Dest Dir: $remoteDestDir"
log_info "  Control Dir: $controllDir"

listFileNameA=list-a.txt
listFileNameB=list-b.txt
localSrcDir=src
localDestDir=dest

main(){
    log_info "Creating local directories..."
    mkdir -p $localDestDir $localSrcDir
    log_success "Local directories created: $localDestDir, $localSrcDir"

    # check if remote dest dir exists (if exists, previous operation failed)
    log_info "Checking remote destination directory status..."
    remoteDestDirCount=$(aws s3 ls ${bucketName}/${remoteDestDir}/ 2>/dev/null | awk "{print \$4}" | wc -l || echo "0")
    log_info "Remote dest dir file count: $remoteDestDirCount"
    
    # list file might not exist
    log_info "Downloading control file if exists..."
    aws s3 cp s3://$bucketName/${controllDir}/${listFileNameA} ./${listFileNameA} 2>/dev/null || true
    touch ./${listFileNameA}
    listFileCount=$(cat ./${listFileNameA} | wc -l)
    log_info "Control file list count: $listFileCount"

    if [[ "$remoteDestDirCount" == "0" && "$listFileCount" == "0" ]]; then
        log_info "No failed jobs detected. Starting fresh upload..."
        upload
    elif [[ "$remoteDestDirCount" != "$listFileCount" ]]; then
        log_info "Upload has failed (count mismatch). Starting over again..."
        upload
    else
        log_info "Upload has succeeded, remote copy has failed. Completing upload..."
        completeUpload
    fi

    log_success "Upload and copy operations completed"
    
    # check it again

    # list all files again
    log_info "Listing all files in source directory for comparison..."
    aws s3 ls ${bucketName}/${remoteSrcDir}/  | awk "{print \$4}" | sort | uniq > ./${listFileNameB}
    listFileBCount=$(cat ./${listFileNameB} | wc -l)
    log_info "Current source file count: $listFileBCount"

    # check diff A and B

    listFileNameTemp=$(mktemp)
    log_info "Checking differences between file lists..."

    diff <(cat ./${listFileNameA}) <(cat ./${listFileNameB}) | grep -E '^(<|>) ' | cut -c3- > $listFileNameTemp

    diffCount=$(cat $listFileNameTemp | wc -l)
    log_info "Difference count: $diffCount"

    if [[ "$diffCount" == "0" ]]; then
        log_info "No differences found. Cleaning up and finishing..."
        aws s3 rm s3://$bucketName/${controllDir}/${listFileNameA}
        rm -rf ./${listFileNameA} ./${listFileNameB} ${listFileNameTemp} ${localSrcDir} ${localDestDir}
        log_success "Script completed successfully"
        return
    else
        log_info "Differences found. Processing new/changed files..."
        uploadLoop ${listFileNameTemp}
    fi
}


upload(){
    log_info "Starting upload process..."
    
    # list all files
    log_info "Listing all files in source directory..."
    aws s3 ls ${bucketName}/${remoteSrcDir}/ | awk "{print \$4}" | sort | uniq > ./${listFileNameA}
    fileCount=$(cat ./${listFileNameA} | wc -l)
    log_info "Found $fileCount files to process"

    # upload listed file, later check if all files uploaded to ${remoteDestDir}
    log_info "Uploading control file..."
    aws s3 cp ./${listFileNameA} s3://$bucketName/${controllDir}/${listFileNameA}
    log_success "Control file uploaded"

    # download all files 
    log_info "Downloading all files from source directory..."
    aws s3 cp s3://$bucketName/${remoteSrcDir} ./${localSrcDir} --recursive
    downloadedCount=$(ls -1 ./${localSrcDir} | wc -l)
    log_success "Downloaded $downloadedCount files"

    # process all files
    log_info "Processing files..."
    processFiles
    processedCount=$(ls -1 ./${localDestDir} | wc -l)
    log_success "Processed $processedCount files"

    # upload all files
    log_info "Uploading processed files to destination..."
    aws s3 cp ./${localDestDir} s3://${bucketName}/${remoteDestDir} --recursive
    log_success "All files uploaded to destination"

    completeUpload
}

completeUpload(){
    log_info "Starting complete upload process..."
    
    # copy all files on remote
    log_info "Copying files from destination back to source..."
    aws s3 cp s3://${bucketName}/${remoteDestDir} s3://${bucketName}/${remoteSrcDir} --recursive
    log_success "Files copied back to source"

    # remove remote dest directory
    log_info "Removing temporary destination directory..."
    aws s3 rm s3://${bucketName}/${remoteDestDir} --recursive
    log_success "Temporary destination directory removed"
}

processFiles(){
    log_info "Processing individual files..."
    fileCount=0
    ls -1 ./${localSrcDir} | while read f; do
        log_info "Processing file: $f"
        cat "$localSrcDir/$f" | jq  '.m += 1' > "$localDestDir/$f"
        fileCount=$((fileCount + 1))
    done
    log_success "File processing completed"
}

# assume that this function is short and do not fail
uploadLoop(){
    listFileNameTemp=$1
    diffCount=$(cat ${listFileNameTemp} | wc -l)
    
    log_info "Starting upload loop with $diffCount differences..."

    if [[ "$diffCount" == "0" ]]; then
        log_info "No differences remaining. Cleaning up..."
        aws s3 rm s3://$bucketName/${controllDir}/${listFileNameA}
        rm -rf ./${listFileNameA} ./${listFileNameB} ${listFileNameTemp} ${localSrcDir} ${localDestDir}
        log_success "Upload loop completed successfully"
        return
    fi

    # for each new files, download.
    log_info "Downloading $diffCount new/changed files..."
    cat ${listFileNameTemp} | while read f; do
        log_info "Downloading: $f"
        aws s3 cp s3://${bucketName}/${remoteSrcDir}/$f ./${localSrcDir}/$f
    done
    log_success "New files downloaded"

    # process downloaded files
    log_info "Processing newly downloaded files..."
    processFiles

    # for each new files, upload.
    log_info "Uploading processed files..."
    cat ${listFileNameTemp} | while read f; do
        log_info "Uploading: $f"
        aws s3 cp ./${localDestDir}/${f} s3://${bucketName}/${remoteDestDir}/${f}
    done
    log_success "New files uploaded"

    rm ${listFileNameTemp}

    completeUpload

    # update file list A with new file list
    log_info "Updating control file list..."
    cp ./${listFileNameB} ./${listFileNameA}

    # upload listed file, later check if all files uploaded to ${remoteDestDir}
    aws s3 cp ./${listFileNameA} s3://$bucketName/${controllDir}/${listFileNameA}
    log_success "Control file updated"

    # list all files again
    log_info "Re-listing source files for next iteration..."
    aws s3 ls ${bucketName}/${remoteSrcDir}/  | awk "{print \$4}" | sort | uniq > ./${listFileNameB}

    # check diff of A and B
    listFileNameTemp=$(mktemp)
    diff <(cat ./${listFileNameA}) <(cat ./${listFileNameB}) | grep -E '^(<|>) ' | cut -c3- > ${listFileNameTemp}

    # run loop again
    log_info "Checking for remaining differences..."
    uploadLoop ${listFileNameTemp}
}

log_info "Script execution started"
main
log_success "Script execution completed"
