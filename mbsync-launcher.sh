#!/usr/bin/env bash

### BEGIN INIT INFO
# Provides:          synthing
# Required-Start:    $network $remote_fs $syslog
# Required-Stop:     $network $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
### END INIT INFO

# a=0;while true; do mbsync -c ../mbsync/mbsync.conf -a ; [[ $((++a % 5)) == 0 ]] && sleep 120; done

_configFile="${HOME}/sync/syncConfig/mails/mbsync/mbsync.conf"
				# Where is stored your mbsync config file
_excludeChannel="channel-mail-test,channel-sent-test"
				# If some channels don't need to be managed
				# by mbsync (comma separated list)
_tmpDir='/tmp'			# Where will be stored temp and logs files
_pidFile="${_tmpDir}/.mbsl.pid"	# Pid file used to know if script is running
_timeWaitSecondBeforeKill=180	# mbsync has 3 minutes to complete before being
				# killed
_timeToThink=10			# Instead of waiting 3 minutes, we check every
				# 10 seconds for mbsync completion
_timeLittleMore=30		# If we're near time to kill mbsync, we also
				# check if mbsync logs are updated. If mbsync
				# still works, we give some time more to
				# complete. Default 30 seconds
_timeHardLimit=300		# If mbsync runs for more than Hard Limit 5 min
				# mbsync is killed.
_waitBetweenLaunch=120		# Wait x seconds before restarting
_parallelRun=0			# Could be useful if you more than one channel
				# in your mbsync config.
				# 0 => No parallel run
				# 1 => All channel launched in parallel
				# >1 => max concurrent channel in parallel
_user="${USER}"			# The user which runs your mbsync
RUN_ONCE=${RUN_ONCE:=1}		# Only run once and don't work for every time


#
# Exit and print message
#
die () {
	printf "%s\n" "${@//%/%%}" >&2
	exit 1
}

#
# Generate a file with pid of running process
#
_createLockFile () {
#	[[ ! -e "${_pidFile}" ]] && { echo -n "${$}::$(< "/proc/${$}/cmdline")" > "${_pidFile}" || die 'Unable to create lock. Aborting...'; }
	local _spid="${$}"
	[[ ! -z "${1:-}" ]] && _spid="${1}"
	printf '%s' "${_spid}::$(< "/proc/${_spid}/cmdline")" > "${_pidFile}" || die 'Unable to create lock. Aborting...';
}

#
# Check if pid file is there and return 0 if running
#
_verifyLockFile () {
#set -xv
	[[ -e "${_pidFile}" && -s "${_pidFile}" ]] && {
		local _pid="$(< "${_pidFile}")"
#echo "${_pid} ----- ${_pid%::*} ----- $(cat "/proc/${_pid%::*}/cmdline")"
		grep -qE "^${$}::" <<< "${_pid}" || {
			[[ "$(cat "/proc/${_pid%::*}/cmdline" 2>/dev/null)" = "${_pid##*::}" ]] || return 1
#			[[ "$(< "/proc/${_pid%::*}/cmdline" 2>/dev/null)" = "${_pid##*::}" ]] || return 1
			export _runningPid="${_pid%::*}"
			return 0
		}
		export _runningPid="${_pid%::*}"
		return 0
	}
	return 1
}

#_verifyLockFile () {
#	[[  -e "${_pidFile}" ]] && {
#		local _pid="$(< "${_pidFile}")"
#		grep -qE "^${$}::" "${_pidFile}" || {
#			[[ "$(< "/proc/${_pid%::*}/cmdline" 2>/dev/null)" = "${_pid##*::}" ]] && die "Process (${_pid%::*} is currently running. Exiting..."
#		}
#	}
#	_createLockFile
#}
_startExecution () {
	trap 'rm -f -- "${_pidFile}" "${_tmpDir}"/.channel-*' INT EXIT
	while true; do
		export _date="$(date "+%Y%m%d")"
		[[ -e "${_pidFile}.stop" ]] && break
		_maxConcurrent=0
		[[ ${_parallelMode:=0} -gt 1 ]] && { _maxConcurrent=${_parallelMode}; }
		while read channel; do
			(
				[[ -e "${_pidFile}.stop" ]] && return 0
		#		date
				[[ -f "${_tmpDir}/.channel-${channel}" ]] && continue
				:> "${_tmpDir}/.channel-${channel}"
				echo "##################### Starting @ $(date)" >> "${_tmpDir}/log.${channel}.${_date}"
#				( mbsync -c "${_configFile}" "${channel}" &>>"/tmp/log.${channel}.${_date}" ) &>/dev/null &
				( mbsync -c "${_configFile}" "${channel}" &>>"/tmp/log.${channel}.${_date}" ) &
				_mbsyncPid=${!}
		#		date
		#		waitToKill ${_mbsyncPid}
				waitToKill ${_mbsyncPid} ${channel} &
				_waiter=${!}
		#		date 
				wait ${_mbsyncPid}
		#		echo removeWaiter ${_waiter}
				
			) &
			_channelWait=${!}
			sleep 1
			[[ ${_parallelMode:=0} -eq 1 ]] && continue
			wait ${_channelWait}
			
		done <<< "${_channels}"
		[[ -e "${_pidFile}.stop" ]] && break
		[[ ${RUN_ONCE} -eq 0 ]] && break
		sleep ${_waitBetweenLaunch:=120}
	done
	rm -f -- "${_pidFile}.stop" "${_pidFile}"
}

#
# Wait and kill process
#
waitToKill () {
	local _pid=${1:-}
	local _channel=${2:-}
	[[ -z "${_pid}" || ${_pid} -eq 1 ]] && _die "God or empty Pid. Aborting..."
	[[ -z "${_channel}" ]] && _die "Channel name empty. Aborting..."
	local _nowStart="$(date "+%s")"; local _now="${_nowStart}"
	local _prevState=''
	while (( $(date "+%s") < _now + _timeWaitSecondBeforeKill)); do
		[[ -s "${_pidFile}.stop" ]] && break
		ps --pid ${_pid} &>/dev/null && sleep ${_thinkTime:=10}
		ps --pid ${_pid} &>/dev/null || break
		local _state="$(tail -1 "${_tmpDir}/log.${_channel}.${_date}" | sha1sum)"
		[[ "${_prevState}" != "${_state}" ]] && {
			_prevState="${_state}"
			(( $(date "+%s") + _timeLittleMore >= _now )) && (( _now+=_timeLittleMore ))
		}
		(( $(date "+%s") > _nowStart + _timeHardLimit )) && break
	done
	ps -u "${_user}" --pid ${_pid} &>/dev/null && kill -9 ${_pid} &>/dev/null
	rm -f -- "${_tmpDir}/.channel-${_channel}"
	echo "##################### Ending @ $(date)" >> "${_tmpDir}/log.${_channel}.${_date}"
}

#
# Print the status
#
_status () {
	_verifyLockFile || die 'No process are running'
	printf '%s\n' "Process (${_runningPid}) is currently running."
	[[ ${_force:=0} -eq 1 ]] && { printf '%s\n' '  --> Currently working on channel(s) :'; for c in "${_tmpDir}"/.channel-* ; do [[ ! -z "${c}" && "${c##*.channel-}" != '*' ]] && printf '%s\n' "      - ${c##*.channel-}"; done; }
	exit 0
}

#
# Stop the process
#
_stop () {
	[[ -e "${_pidFile}.stop" ]] && printf '%s\n' 'Stop was already requested.'
	printf '%s\n' "Requesting stop. Please wait..."
	:> "${_pidFile}.stop"
	[[ ${_force:=0} -eq 1 ]] && printf '%s' 'force' > "${_pidFile}.stop"
	sleep ${_thinkTime:=10}
	[[ ! -e "${_pidFile}" ]] && printf '%s\n' 'All process should have been stopped'
}

#
# Start the process
#
_start () {
#set -xv
	_verifyLockFile && die "Process (${_runningPid}) is currently running."
	_createLockFile
	rm -f -- "${_pidFile}.stop"
#	_startExecution 
	( _startExecution &>/dev/null ) &
	_createLockFile "${!}"
	sleep 2
	_status
}

# Delete temp files
##trap 'rm -f -- "${_pidFile}" "${_tmpDir}"/.channel-*' INT EXIT
#trap 'rm -f -- "${_pidFile}" "${_tmpDir}"/.channel-*' EXIT

# List of account
_channels="$(sed -e '/^[[:space:]]*Channel/!d;s/^[[:space:]]*Channel[[:space:]]*//' "${_configFile}")"

# Check if there is any channel in the config file...
[[ -z "${_channels// 	/}" ]] && die "No channel in '${_configFile}'"


_argv="${1:-}"
[[ ${#} -gt 1 ]] && { shift; _requester="${@}"; }
case "${_argv,,}" in
	start) _start "${_requester:=}";;
	stop) _stop "${_requester:=}";;
	forcestop) _force=1 _stop;;
	info) _force=1 _status "${_requester:=}";;
	status) _status "${_requester:=}";;
	restart) _force=1 _stop "${_requester:=}"; sleep 2; _start "${_requester:=}";;
	*) echo "usage: ${0} [start|status|info|stop|forcestop|restart]" >&2 ;;
esac







exit 0

#
##############################################################################
#




# Une putain de bonne grosse verif de PID
# <------------ là
# echo "$$ - $(cat /proc/$$/cmdline)"
# _verifyLockFile

#sleep 500
#exit 0
#[[ ! -e "${_pidFile}" ]] && { echo -n "${$}::$(< "/proc/${$}/cmdline")" > "${_pidFile}" || die 'Unable to create lock. Aborting.'; }
#[[ -e "${_pidFile}" ]] && {  }
#[[ -e "/proc/${$}/cdline" ]] && 
# SI personne on supprime tous les /tmp/.channel-*




_maxConcurrent=0
[[ ${_parallelMode:=0} -gt 1 ]] && { _maxConcurrent=${_parallelMode}; }
while read channel; do
	(
		[[ -e "${_pidFile}.stop" ]] && return 0
#		date
		[[ -f "${_tmpDir}/.channel-${channel}" ]] && continue
		:> "${_tmpDir}/.channel-${channel}"
		echo "##################### Starting @ $(date)" >> "${_tmpDir}/log.${channel}"
		( mbsync -c "${_configFile}" "${channel}" &>>/tmp/log.${channel} ) &
		_mbsyncPid=${!}
#		date
#		waitToKill ${_mbsyncPid}
		waitToKill ${_mbsyncPid} ${channel} &
		_waiter=${!}
#		date 
		wait ${_mbsyncPid}
#		echo removeWaiter ${_waiter}
		
	) &
	_channelWait=${!}
	sleep 1
	[[ ${_parallelMode:=0} -eq 1 ]] && continue
	wait ${_channelWait}
	
done <<< "${_channels}"

exit 0



# $Format:%cn @ %cD$ : $Id: 46fe3b0647de7136b877dec1c34202b15807db2e $
