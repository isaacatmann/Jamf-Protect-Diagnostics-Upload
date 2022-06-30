#!/bin/zsh
###############################################################################
# Jamf Protect Diagnostics Upload
# Created by: Mann Consulting (support@mann.com)
# Summary:
#     Captures logging data for Jamf Protect and upploads to S3 for easy submittal to Jamf.
#     The employee will be prompted to answer questions generally asked by Jamf support,
#     This will save considerable back/forth questions when reporting issues.
#
#     SECURITY CONCERN: IAM Key and Secret will be shown in the process list on the computer,
#     take appropriate security precautions to make sure that the IAM user is restricted.
#     You should create a dedicated S3 bucket and make the IAM WRITE ONLY just for that bucket.
#
#
# Arguments:
#     1-3 are reserved by Jamf Pro
#     4: S3 Write only IAM Key
#     5: S3 Write only IAM Secret
#     6: S3 Bucket Name
#     7: Datadog API key, Logging level (i.e. 4848200000000000000a68c7bb,INFO)
#     8:
#     9:
#     10:
#     11: Variable Overrides, seperated by semicolin (i.e. NOTIFY=silent;FORCEFULLUPDATE=YES)
# Exit Codes:
#     0: Sucessful!
#     1: Generic Error, undefined
#
# Useage:
#     Run as part of a policy as needed to gather logs.
#
# Do Note:
#     This script is part of Mann Consulting's Jamf Pro Maintenance subscription.
#     If you'd like updates or support sign up at https://mann.com/jamf or
#     email support@mann.com for more details
###############################################################################
VERSIONDATE='20211103'
APPLICATION="JamfProtectDiagnostics"
currentUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')

### Start Logging
# LOGGING applies to local out put and will be captured by Jamf
# DATADOGLOGGING will apply to what type of logs we send to Datadog.  We pull this from Jamf varaiables so they're persistant to the client.
#
# Logging Levels
# ERROR - Only fatal errors
# WARN - Fatal errors and warnings
# INFO - All messages, no user identifiable data
# DEBUG - Debug logging may inclue user identifiable data.
#
# SESSIONID
# Randomly generated number for this session.

if [[ -z $LOGGING ]]; then
  LOGGING=INFO
fi
JSSURL=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)

SESSIONID=$RANDOM
if [[ -n $7 ]]; then
  DATADOGAPI=$(echo $7 | cut -d ',' -f 1)
  DATADOGLOGGING=$(echo $7 | cut -d ',' -f 2)
fi

declare -A levels=(DEBUG 0 INFO 1 WARN 2 ERROR 3)

printlog(){
  [ -z "$2" ] && 2=INFO
  log_message=$1
  log_priority=$2
  timestamp=$(date +%F\ %T)
  if [[ "$log_message" == "$previous_log_message" ]];then
    let logrepeat=$logrepeat+1
    return
  fi
  previous_log_message=$log_message
  if [[ $logrepeat -gt 1 ]];then
    echo "$timestamp" "${log_priority} : $JSSURL : $APPLICATION : $VERSIONDATE : $SESSIONID : Last Log repeated ${logrepeat} times"
    if [[ ! -z $DATADOGAPI ]]; then
      curl -s -X POST https://http-intake.logs.datadoghq.com/v1/input -H "Content-Type: text/plain" -H "DD-API-KEY: $DATADOGAPI" -d "${log_priority} : $JSSURL : $APPLICATION : $VERSIONDATE : $SESSIONID : Last Log repeated ${logrepeat} times" > /dev/null
    fi
    logrepeat=0
  fi

  if [[ -n $DATADOGAPI && ${levels[$log_priority]} -ge ${levels[$DATADOGLOGGING]} ]]; then
    while IFS= read -r logmessage; do
      curl -s -X POST https://http-intake.logs.datadoghq.com/v1/input -H "Content-Type: text/plain" -H "DD-API-KEY: $DATADOGAPI" -d "${log_priority} : $JSSURL : $APPLICATION : $VERSIONDATE : $SESSIONID : ${logmessage}" > /dev/null
    done <<< "$log_message"
  fi

  if [[ ${levels[$log_priority]} -ge ${levels[$LOGGING]} ]]; then
    while IFS= read -r logmessage; do
      echo "$timestamp" "${log_priority} : $JSSURL : $APPLICATION : $VERSIONDATE : $SESSIONID : ${logmessage}"
    done <<< "$log_message"
  fi
}
### End Logging
printlog "################## Start $APPLICATION" INFO

TARGET=JamfProtect
LOGROOT=$(mktemp -d)
LOGPATH=$LOGROOT/JamfProtectDiagnostics
VERSION=$(protectctl version | awk '{ print $2 }')
JSSHOST=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url | cut -d '/' -f 3)
icon="/Applications/JamfProtect.app/Contents/Resources/AppIcon.icns"
#S3 parameters
S3KEY="${4}"
S3SECRET="${5}"
S3BUCKET="${6}"
S3STORAGETYPE="STANDARD" #REDUCED_REDUNDANCY or STANDARD etc.
AWSREGION="s3-us-west-2"

putS3(){

  file_path=$1
  aws_path=/
  bucket="${S3BUCKET}"
  date=$(date -R)
  acl="x-amz-acl:private"
  content_type="application/x-compressed-tar"
  storage_type="x-amz-storage-class:${S3STORAGETYPE}"
  string="PUT\n\n$content_type\n$date\n$acl\n$storage_type\n/$bucket$aws_path${file_path##/*/}"
  signature=$(echo -en "${string}" | openssl sha1 -hmac "${S3SECRET}" -binary | base64)
  curl -s --retry 3 --retry-delay 10 -X PUT -T "$file_path" \
       -H "Host: $bucket.${AWSREGION}.amazonaws.com" \
       -H "Date: $date" \
       -H "Content-Type: $content_type" \
       -H "$storage_type" \
       -H "$acl" \
       -H "Authorization: AWS ${S3KEY}:$signature" \
       "https://$bucket.${AWSREGION}.amazonaws.com$aws_path${file_path##/*/}"
}

if [[ $EUID -ne 0 ]]; then
	printlog "This script must be run as root" ERROR
  printlog "################## End $APPLICATION" INFO
  exit 1
fi

UserInputIssue=`osascript -e 'display dialog "Please give a description of the issue you are experiencing with Jamf Protect, the more information the better." buttons {"OK"} default button "OK" default answer "\n\n\n\n\n\n\n\n\n\n" with icon POSIX file ("'$icon'" as string)'`
UserInputDoing=`osascript -e 'display dialog "What were you doing while the issue occurred? Examples: Running a report in Excel, compiling a project..." buttons {"OK"} default button "OK" default answer "\n\n\n\n\n\n\n\n\n\n" with icon POSIX file ("'$icon'" as string)'`

## Create a temporary storage folder
/bin/mkdir $LOGPATH
echo "Answer to please give a description of the issue you are experiencing with Jamf Protect: $UserInputIssue" > $LOGPATH/UserFeedback.txt
echo "Answer to what were you doing while the issue occured: $UserInputDoing" >> $LOGPATH/UserFeedback.txt

## Let's gather any available diagnostic logs
printlog "Gathering any available diagnostic reports..." INFO
/bin/mkdir $LOGROOT/DiagnosticReports
/usr/bin/find /Library/Logs/DiagnosticReports -type f -name "JamfProtect*" -exec cp {} /private/tmp/DiagnosticReports \;
/usr/bin/zip -j -r $LOGPATH/DiagnosticReports.zip $LOGROOT/DiagnosticReports/*

## Let's gather the Jamf Protect agent information
printlog "Gathering information about the Jamf Protect agent configuration" INFO
/usr/local/bin/protectctl info -v > $LOGPATH/agentInfo.txt

## Let's gather historical activity from the Jamf Protect daemon
printlog "Gathering historical Jamf Protect daemon activity..." INFO
/usr/bin/log show --debug --predicate "subsystem == 'com.jamf.protect.daemon' && category != 'Cache'" > $LOGPATH/daemonActivity.txt

/usr/bin/log show --debug --predicate "processImagePath CONTAINS 'JamfProtect'" --info > $LOGPATH/JamfProtect.processImagePath.LogActivity.txt

printlog "Enumerating open files..." INFO
/usr/sbin/lsof -c $TARGET > $LOGPATH/lsof.txt

printlog "Monitoring file access (10 seconds)..." INFO
/usr/bin/fs_usage -w -f filesystem -t 10 | grep $TARGET > $LOGPATH/fs.txt

printlog "Sampling process space (10 seconds)..." INFO
/usr/bin/sample -file $LOGPATH/sample.txt $TARGET

printlog "Getting System Profiler data" INFO
/usr/sbin/system_profiler &> $LOGPATH/system_profiler.txt

printlog "Capturing process information..." INFO
/usr/bin/top -l20 > $LOGPATH/top.txt

printlog "Capturing power metrics (10 seconds)..." INFO
/usr/bin/powermetrics -a 0 -i 1000 -n 10 -s tasks --show-process-energy > $LOGPATH/power.txt

printlog "Capturing System Keychain"
security dump-keychain /Library/Keychains/System.keychain &> $LOGPATH/System.keychain.dump.txt

logfilezip=$LOGROOT/JamfProtectDiagnostics-${JSSHOST}-v${VERSION}-${currentUser}-$(date +"%m-%d-%Y-%H-%M").zip
printlog "Zipping up results as $logfilezip" INFO
/usr/bin/zip -j -r ${logfilezip} $LOGPATH/*


printlog "Uploading file to S3" INFO
putS3 $logfilezip

printlog "Deleting files" INFO
rm -Rf $LOGROOT/

osascript -e 'display dialog "Your report has been submitted, we will review it for issues." buttons {"OK"} default button "OK"  with icon POSIX file ("'$icon'" as string)' &

printlog "################## End $APPLICATION" INFO
