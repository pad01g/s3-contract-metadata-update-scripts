#!/bin/bash

if [[ "$#" != "4" ]]; then
    echo "$0 [bucketName] [remoteSrcDir] [remoteDestDir] [controllDir]";
fi

bucketName=$1
remoteSrcDir=$2
remoteDestDir=$3
controllDir=$4

listFileNameA=list-a.txt
listFileNameB=list-b.txt
localSrcDir=src
localDestDir=dest

main(){
    mkdir -p $localDestDir

    # check if remote dest dir exists (if exists, previous operation failed)

    remoteDestDirCount=$(aws s3 ls ${bucketName}/${remoteDestDir}/ | awk "{print \$4}" | wc -l)
    # list file might not exist
    aws s3 cp s3://$bucketName/${controllDir}/${listFileNameA} ./${listFileNameA}
    touch ./${listFileNameA}
    listFileCount=$(cat ./${listFileNameA} | wc -l)

    if [[ "$remoteDestDirCount" == "0" && "$listFileCount" == "0" ]]; then
        # no failed jobs.
        upload
    elif [[ "$remoteDestDirCount" != "$listFileCount" ]]; then
        # upload has failed, start over again.
        upload
    else
        # upload has succeeded, remote copy has failed.
        completeUpload
    fi

    # now you must have local and remote ${listFileNameA} synced.
    
    # check it again

    # list all files again

    aws s3 ls ${bucketName}/${remoteSrcDir}/  | awk "{print \$4}" | sort | uniq > ./${listFileNameB}

    # check diff A and B

    listFileNameTemp=$(mktemp)

    diff <(cat ./${listFileNameA}) <(cat ./${listFileNameB}) | grep -E '^(<|>) ' | cut -c3- > $listFileNameTemp

    if [[ $(cat $listFileNameTemp | wc -l ) == "0" ]]; then
        # if there is no difference, remove remote/local file and finish.
        aws s3 rm s3://$bucketName/${controllDir}/${listFileNameA}
        rm -rf ./${listFileNameA} ./${listFileNameB} ${listFileNameTemp} ${localSrcDir} ${localDestDir}
        return
    else
        # if there is difference, check difference 
        uploadLoop ${listFileNameTemp}
    fi
}


upload(){
    # list all files

    aws s3 ls ${bucketName}/${remoteSrcDir}/ | awk "{print \$4}" | sort | uniq > ./${listFileNameA}

    # upload listed file, later check if all files uploaded to ${remoteDestDir}
    aws s3 cp ./${listFileNameA} s3://$bucketName/${controllDir}/${listFileNameA}

    # download all files 

    aws s3 cp s3://$bucketName/${remoteSrcDir} ./${localSrcDir} --recursive

    # process all files
    processFiles

    # upload all files

    aws s3 cp ./${localDestDir} s3://${bucketName}/${remoteDestDir} --recursive

    completeUpload
}

completeUpload(){
    # copy all files on remote

    aws s3 cp s3://${bucketName}/${remoteDestDir} s3://${bucketName}/${remoteSrcDir} --recursive

    # remove remote dest directory

    aws s3 rm s3://${bucketName}/${remoteDestDir} --recursive
}

processFiles(){
    ls -1 ./${localSrcDir} | while read f; do
        cat "$localSrcDir/$f" | jq  '.m += 1' > "$localDestDir/$f"
    done
}

# assume that this function is short and do not fail
uploadLoop(){
    listFileNameTemp=$1

    if [[ $(cat ${listFileNameTemp} | wc -l) == "0" ]]; then
        # list diff is empty, quit
        rm -rf ./${listFileNameA} ./${listFileNameB} ${listFileNameTemp} ${localSrcDir} ${localDestDir}
        return
    fi

    # for each new files, download.
    cat ${listFileNameTemp} | while read f; do
        aws s3 cp s3://${bucketName}/${remoteSrcDir}/$f ./${localSrcDir}/$f
    done

    rm ${listFileNameTemp}

    # process downloaded files
    processFiles

    # upload files
    aws s3 cp ./${localDestDir} s3://${bucketName}/${remoteDestDir} --recursive

    completeUpload

    # update file list A with new file list
    cp ./${listFileNameB} ./${listFileNameA}

    # upload listed file, later check if all files uploaded to ${remoteDestDir}
    aws s3 cp ./${listFileNameA} s3://$bucketName/${controllDir}/${listFileNameA}

    # list all files again
    aws s3 ls ${bucketName}/${remoteSrcDir}/  | awk "{print \$4}" | sort | uniq > ./${listFileNameB}


    # check diff of A and B
    diff <(cat ./${listFileNameA}) <(cat ./${listFileNameB}) | grep -E '^(<|>) ' | cut -c3- > ${listFileNameTemp}

    # run loop again
    uploadLoop ${listFileNameTemp}
}

main
