#!/usr/bin/env bash

## Installer script suitable for osync / obackup / pmocr

_OFUNCTIONS_BOOTSTRAP=true

PROGRAM=osync

PROGRAM_VERSION=$(grep "PROGRAM_VERSION=" $PROGRAM.sh)
PROGRAM_VERSION=${PROGRAM_VERSION#*=}
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SSH_FILTER="ssh_filter.sh"

SCRIPT_BUILD=2018062601

## osync / obackup / pmocr / zsnap install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8, 10 and 11
## Please adapt this to fit your distro needs

# Get current install.sh path from http://stackoverflow.com/a/246128/2635443
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

_LOGGER_SILENT=false
_STATS=1
ACTION="install"
FAKEROOT=""

function GetCommandlineArguments {
        for i in "$@"; do
                case $i in
			--prefix=*)
                        FAKEROOT="${i##*=}"
                        ;;
			--silent)
			_LOGGER_SILENT=true
			;;
			--no-stats)
			_STATS=0
			;;
			--remove)
			ACTION="uninstall"
			;;
			--help|-h|-?)
			Usage
			;;
                        *)
			Logger "Unknown option '$i'" "SIMPLE"
			Usage
			exit
                        ;;
                esac
	done
}

GetCommandlineArguments "$@"

CONF_DIR=$FAKEROOT/etc/$PROGRAM
BIN_DIR="$FAKEROOT/usr/local/bin"
SERVICE_DIR_INIT=$FAKEROOT/etc/init.d
# Should be /usr/lib/systemd/system, but /lib/systemd/system exists on debian & rhel / fedora
SERVICE_DIR_SYSTEMD_SYSTEM=$FAKEROOT/lib/systemd/system
SERVICE_DIR_SYSTEMD_USER=$FAKEROOT/etc/systemd/user
SERVICE_DIR_OPENRC=$FAKEROOT/etc/init.d

if [ "$PROGRAM" == "osync" ]; then
	SERVICE_NAME="osync-srv"
elif [ "$PROGRAM" == "pmocr" ]; then
	SERVICE_NAME="pmocr-srv"
fi

SERVICE_FILE_INIT="$SERVICE_NAME"
SERVICE_FILE_SYSTEMD_SYSTEM="$SERVICE_NAME@.service"
SERVICE_FILE_SYSTEMD_USER="$SERVICE_NAME@.service.user"
SERVICE_FILE_OPENRC="$SERVICE_NAME-openrc"

## Generic code

## Default log file
if [ -w "$FAKEROOT/var/log" ]; then
	LOG_FILE="$FAKEROOT/var/log/$PROGRAM-install.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM-install.log"
else
	LOG_FILE="./$PROGRAM-install.log"
fi

#### RemoteLogger SUBSET ####

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" != "" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		fi
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}
#### RemoteLogger SUBSET END ####

# General log function with log levels:

# Environment variables
# _LOGGER_SILENT: Disables any output to stdout & stderr
# _LOGGER_ERR_ONLY: Disables any output to stdout except for ALWAYS loglevel
# _LOGGER_VERBOSE: Allows VERBOSE loglevel messages to be sent to stdout

# Loglevels
# Except for VERBOSE, all loglevels are ALWAYS sent to log file

# CRITICAL, ERROR, WARN sent to stderr, color depending on level, level also logged
# NOTICE sent to stdout
# VERBOSE sent to stdout if _LOGGER_VERBOSE = true
# ALWAYS is sent to stdout unless _LOGGER_SILENT = true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=yes
# SIMPLE is a wrapper for QuickLogger that does not use advanced functionality
function Logger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	## Obfuscate _REMOTE_TOKEN in logs (for ssh_filter usage only in osync and obackup)
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/__(o_O)__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/__(o_O)__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT is not set in main when Logger is called from a subprocess. Need to keep this flag.
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[91m$value\e[0m" true
		ERROR_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[33m$value\e[0m" true
		WARN_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.warn.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ "$_LOGGER_ERR_ONLY" != true ]; then
			_Logger "$prefix$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "$prefix($level):$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger "$prefix$value" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "$prefix$value" "$prefix\e[35m$value\e[0m"	#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	elif [ "$level" == "SIMPLE" ]; then
		if [ "$_LOGGER_SILENT" == true ]; then
			_Logger "$preix$value"
		else
			_Logger "$preix$value" "$prefix$value"
		fi
		return
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
	fi
}
## Modified version of https://gist.github.com/cdown/1163649
function UrlEncode {
	local length="${#1}"

	local LANG=C
	for i in $(seq 0 $((length-1))); do
		local c="${1:i:1}"
		case $c in
			[a-zA-Z0-9.~_-])
			printf "$c"
			;;
			*)
			printf '%%%02X' "'$c"
			;;
		esac
	done
}
function GetLocalOS {
	local localOsVar
	local localOsName
	local localOsVer

	# There is no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? != 0 ]; then
					localOsVar="$(uname)"
				fi
			fi
		fi
	fi

	case $localOsVar in
		# Android uname contains both linux and android, keep it before linux entry
		*"Android"*)
		LOCAL_OS="Android"
		;;
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"MINGW64"*|*"MSYS"*)
		LOCAL_OS="msys"
		;;
		*"CYGWIN"*)
		LOCAL_OS="Cygwin"
		;;
		*"Microsoft"*)
		LOCAL_OS="WinNT10"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BusyBox"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		if [ "$_OFUNCTIONS_VERSION" != "" ]; then
			Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		fi
		exit 1
		;;
	esac

	# Get linux versions
	if [ -f "/etc/os-release" ]; then
		localOsName=$(GetConfFileValue "/etc/os-release" "NAME" true)
		localOsVer=$(GetConfFileValue "/etc/os-release" "VERSION" true)
	elif [ "$LOCAL_OS" == "BusyBox" ]; then
		localOsVer=`ls --help 2>&1 | head -1 | cut -f2 -d' '`
		localOsName="BusyBox"
	fi

	# Get Host info for Windows
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Cygwin" ] || [ "$LOCAL_OS" == "WinNT10" ]; then localOsVar="$(uname -a)"
		if [ "$PROGRAMW6432" != "" ]; then
			LOCAL_OS_BITNESS=64
			LOCAL_OS_FAMILY="Windows"
		elif [ "$PROGRAMFILES" != "" ]; then
			LOCAL_OS_BITNESS=32
			LOCAL_OS_FAMILY="Windows"
		# Case where running on BusyBox but no program files defined
		elif [ "$LOCAL_OS" == "BusyBox" ]; then
			LOCAL_OS_FAMILY="Unix"
		fi
	# Get Host info for Unix
	else
		LOCAL_OS_FAMILY="Unix"
		if uname -m | grep '64' > /dev/null 2>&1; then
			LOCAL_OS_BITNESS=64
		else
			LOCAL_OS_BITNESS=32
		fi
	fi

	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer) $LOCAL_OS_BITNESS-bit $LOCAL_OS_FAMILY"

	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$LOCAL_OS_FULL]." "DEBUG"
	fi
}
function GetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local noError="${3:-false}"

	local value

	value=$(grep "^$name=" "$file")
	if [ $? == 0 ]; then
		value="${value##*=}"
		echo "$value"
	else
		if [ $noError == true ]; then
			Logger "Cannot get value for [$name] in config file [$file]." "NOTICE"
		else
			Logger "Cannot get value for [$name] in config file [$file]." "ERROR"
		fi
	fi
}


function SetLocalOSSettings {
	USER=root

	# LOCAL_OS and LOCAL_OS_FULL are global variables set at GetLocalOS

	case $LOCAL_OS in
		*"BSD"*)
		GROUP=wheel
		;;
		*"MacOSX"*)
		GROUP=admin
		;;
		*"msys"*|*"Cygwin"*)
		USER=""
		GROUP=""
		;;
		*)
		GROUP=root
		;;
	esac

	if [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "BusyBox" ]; then
		Logger "Cannot be installed on [$LOCAL_OS]. Please use $PROGRAM.sh directly." "SIMPLE"
		exit 1
	fi

	if ([ "$USER" != "" ] && [ "$(whoami)" != "$USER" ] && [ "$FAKEROOT" == "" ]); then
		Logger "Must be run as $USER." "SIMPLE"
		exit 1
	fi

	OS=$(UrlEncode "$LOCAL_OS_FULL")
}

function GetInit {
	if [ -f /sbin/openrc-run ]; then
		init="openrc"
		Logger "Detected openrc." "SIMPLE"
	elif [ -f /sbin/init ]; then
		if file /sbin/init | grep systemd > /dev/null; then
			init="systemd"
			Logger "Detected systemd." "SIMPLE"
		else
			init="initV"
			Logger "Detected initV." "SIMPLE"
		fi
	else
		Logger "Can't detect initV or systemd. Service files won't be installed. You can still run $PROGRAM manually or via cron." "SIMPLE"
		init="none"
	fi
}

function CreateDir {
	local dir="${1}"

	if [ ! -d "$dir" ]; then
		mkdir -p "$dir"
		if [ $? == 0 ]; then
			Logger "Created directory [$dir]." "SIMPLE"
		else
			Logger "Cannot create directory [$dir]." "SIMPLE"
			exit 1
		fi
	fi
}

function CopyFile {
	local sourcePath="${1}"
	local destPath="${2}"
	local sourceFileName="${3}"
	local destFileName="${4}"
	local fileMod="${5}"
	local fileUser="${6}"
	local fileGroup="${7}"
	local overwrite="${8:-false}"

	local userGroup=""
	local oldFileName

	if [ "$destFileName" == "" ]; then
		destFileName="$sourceFileName"
	fi

	if [ -f "$destPath/$destFileName" ] && [ $overwrite == false ]; then
		destfileName="$sourceFileName.new"
		Logger "Copying [$sourceFileName] to [$destPath/$destFilename]." "SIMPLE"
	fi

	cp "$sourcePath/$sourceFileName" "$destPath/$destFileName"
	if [ $? != 0 ]; then
		Logger "Cannot copy [$sourcePath/$sourceFileName] to [$destPath/$destFileName]. Make sure to run install script in the directory containing all other files." "SIMPLE"
		Logger "Also make sure you have permissions to write to [$BIN_DIR]." "SIMPLE"
		exit 1
	else
		Logger "Copied [$sourcePath/$sourceFileName] to [$destPath/$destFileName]." "SIMPLE"
		if [ "$fileMod" != "" ]; then
			chmod "$fileMod" "$destPath/$destFileName"
			if [ $? != 0 ]; then
				Logger "Cannot set file permissions of [$destPath/$destFileName] to [$fileMod]." "SIMPLE"
				exit 1
			else
				Logger "Set file permissions to [$fileMod] on [$destPath/$destFileName]." "SIMPLE"
			fi
		fi

		if [ "$fileUser" != "" ]; then
			userGroup="$fileUser"

			if [ "$fileGroup" != "" ]; then
				userGroup="$userGroup"":$fileGroup"
			fi

			chown "$userGroup" "$destPath/$destFileName"
			if [ $? != 0 ]; then
				Logger "Could not set file ownership on [$destPath/$destFileName] to [$userGroup]." "SIMPLE"
				exit 1
			else
				Logger "Set file ownership on [$destPath/$destFileName] to [$userGroup]." "SIMPLE"
			fi
		fi
	fi
}

function CopyExampleFiles {
	exampleFiles=()
	exampleFiles[0]="sync.conf.example"		# osync
	exampleFiles[1]="host_backup.conf.example"	# obackup
	exampleFiles[2]="exclude.list.example"		# osync & obackup
	exampleFiles[3]="snapshot.conf.example"		# zsnap
	exampleFiles[4]="default.conf"			# pmocr

	for file in "${exampleFiles[@]}"; do
		if [ -f "$SCRIPT_PATH/$file" ]; then
			CopyFile "$SCRIPT_PATH" "$CONF_DIR" "$file" "$file" "" "" "" false
		fi
	done
}

function CopyProgram {
	binFiles=()
	binFiles[0]="$PROGRAM_BINARY"
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		binFiles[1]="$PROGRAM_BATCH"
		binFiles[2]="$SSH_FILTER"
	fi

	local user=""
	local group=""

	if ([ "$USER" != "" ] && [ "$FAKEROOT" == "" ]); then
		user="$USER"
	fi
	if ([ "$GROUP" != "" ] && [ "$FAKEROOT" == "" ]); then
		group="$GROUP"
	fi

	for file in "${binFiles[@]}"; do
		CopyFile "$SCRIPT_PATH" "$BIN_DIR" "$file" "$file" 755 "$user" "$group" true
	done
}

function CopyServiceFiles {
	if ([ "$init" == "systemd" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		CreateDir "$SERVICE_DIR_SYSTEMD_SYSTEM"
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_SYSTEM" "$SERVICE_FILE_SYSTEMD_SYSTEM" "$SERVICE_FILE_SYSTEMD_SYSTEM" "" "" "" true
		if [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_USER" ]; then
			CreateDir "$SERVICE_DIR_SYSTEMD_USER"
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_USER" "$SERVICE_FILE_SYSTEMD_USER" "$SERVICE_FILE_SYSTEMD_USER" "" "" "" true
		fi

		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]." "SIMPLE"
		Logger "Can be activated with [systemctl start SERVICE_NAME@instance.conf] where instance.conf is the name of the config file in $CONF_DIR." "SIMPLE"
		Logger "Can be enabled on boot with [systemctl enable $SERVICE_NAME@instance.conf]." "SIMPLE"
		Logger "In userland, active with [systemctl --user start $SERVICE_NAME@instance.conf]." "SIMPLE"
	elif ([ "$init" == "initV" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_INIT" ] && [ -d "$SERVICE_DIR_INIT" ]); then
		#CreateDir "$SERVICE_DIR_INIT"
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_INIT" "$SERVICE_FILE_INIT" "$SERVICE_FILE_INIT" "755" "" "" true

		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_INIT]." "SIMPLE"
		Logger "Can be activated with [service $SERVICE_FILE_INIT start]." "SIMPLE"
		Logger "Can be enabled on boot with [chkconfig $SERVICE_FILE_INIT on]." "SIMPLE"
	elif ([ "$init" == "openrc" && [ -f "$SCRIPT_PATH/$SERVICE_FILE_OPENRC" ] && [ -d "$SERVICE_DIR_OPENRC" ]); then
		# Rename service to usual service file
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_OPENRC" "$SERVICE_FILE_OPENRC" "$SERVICE_FILE_INIT" "755" "" "" true

		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_OPENRC]." "SIMPLE"
		Logger "Can be activated with [rc-update add $SERVICE_NAME.instance] where instance is a configuration file found in /etc/osync." "SIMPLE"
	else
		Logger "Cannot define what init style is in use on this system. Skipping service file installation." "SIMPLE"
	fi
}

function Statistics {
	if type wget > /dev/null; then
		wget -qO- "$STATS_LINK" > /dev/null 2>&1
		if [ $? == 0 ]; then
			return 0
		fi
	fi

	if type curl > /dev/null; then
		curl "$STATS_LINK" -o /dev/null > /dev/null 2>&1
		if [ $? == 0 ]; then
			return 0
		fi
	fi

	Logger "Neiter wget nor curl could be used for. Cannot run statistics. Use the provided link please." "SIMPLE"
	return 1
}

function RemoveFile {
	local file="${1}"

	if [ -f "$file" ]; then
		rm -f "$file"
		if [ $? != 0 ]; then
			Logger "Could not remove file [$file]." "SIMPLE"
		else
			Logger "Removed file [$file]." "SIMPLE"
		fi
	else
		Logger "File [$file] not found. Skipping." "SIMPLE"
	fi
}

function RemoveAll {
	RemoveFile "$BIN_DIR/$PROGRAM_BINARY"

	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		RemoveFile "$BIN_DIR/$PROGRAM_BATCH"
	fi

	if [ ! -f "$BIN_DIR/osync.sh" ] && [ ! -f "$BIN_DIR/obackup.sh" ]; then		# Check if any other program requiring ssh filter is present before removal
		RemoveFile "$BIN_DIR/$SSH_FILTER"
	else
		Logger "Skipping removal of [$BIN_DIR/$SSH_FILTER] because other programs present that need it." "SIMPLE"
	fi
	RemoveFile "$SERVICE_DIR_SYSTEMD_SYSTEM/$SERVICE_FILE_SYSTEMD_SYSTEM"
	RemoveFile "$SERVICE_DIR_SYSTEMD_USER/$SERVICE_FILE_SYSTEMD_USER"
	RemoveFile "$SERVICE_DIR_INIT/$SERVICE_FILE_INIT"

	Logger "Skipping configuration files in [$CONF_DIR]. You may remove this directory manually." "SIMPLE"
}

function Usage {
	echo "Installs $PROGRAM into $BIN_DIR"
	echo "options:"
	echo "--silent		Will log and bypass user interaction."
	echo "--no-stats	Used with --silent in order to refuse sending anonymous install stats."
	echo "--remove          Remove the program."
	echo "--prefix=/path    Use prefix to install path."
	exit 127
}

GetLocalOS
SetLocalOSSettings
GetInit

STATS_LINK="http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION&os=$OS&action=$ACTION"

if [ "$ACTION" == "uninstall" ]; then
	RemoveAll
	Logger "$PROGRAM uninstalled." "SIMPLE"
else
	CreateDir "$CONF_DIR"
	CreateDir "$BIN_DIR"
	CopyExampleFiles
	CopyProgram
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "pmocr" ]; then
		CopyServiceFiles
	fi
	Logger "$PROGRAM installed. Use with $BIN_DIR/$PROGRAM" "SIMPLE"
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		echo ""
		Logger "If connecting remotely, consider setup ssh filter to enhance security." "SIMPLE"
		echo ""
	fi
fi

if [ $_STATS -eq 1 ]; then
	if [ $_LOGGER_SILENT == true ]; then
		Statistics
	else
		Logger "In order to make usage statistics, the script would like to connect to $STATS_LINK" "SIMPLE"
		read -r -p "No data except those in the url will be send. Allow [Y/n] " response
		case $response in
			[nN])
			exit
			;;
			*)
			Statistics
			exit $?
			;;
		esac
	fi
fi
