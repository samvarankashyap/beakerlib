# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Name: journal.sh - part of the BeakerLib project
#   Description: Journalling functionality
#
#   Author: Petr Muller <pmuller@redhat.com>
#   Author: Jan Hutar <jhutar@redhat.com>
#   Author: Ales Zelinka <azelinka@redhat.com>
#   Author: Petr Splichal <psplicha@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2008-2010 Red Hat, Inc. All rights reserved.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

: <<'=cut'
=pod

=head1 NAME

BeakerLib - journal - journalling functionality

=head1 DESCRIPTION

Routines for initializing the journalling features and pretty
printing journal contents.

=head1 FUNCTIONS

=cut

__INTERNAL_JOURNALIST=beakerlib-journalling


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalStart
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head2 Journalling

=head3 rlJournalStart

Initialize the journal file.

    rlJournalStart

Run on the very beginning of your script to initialize journalling
functionality.

=cut

rlJournalStart(){
    # test-specific temporary directory for journal/metadata
    if [ -n "$BEAKERLIB_DIR" ]; then
        # try user-provided temporary directory first
        true
    elif [ -n "$TESTID" ]; then
        # if available, use TESTID for the temporary directory
        # - this is useful for preserving metadata through a system reboot
        export BEAKERLIB_DIR="$__INTERNAL_PERSISTENT_TMP/beakerlib-$TESTID"
    else
        # else generate a random temporary directory
        export BEAKERLIB_DIR=$(mktemp -d $__INTERNAL_PERSISTENT_TMP/beakerlib-XXXXXXX)
    fi

    [ -d "$BEAKERLIB_DIR" ] || mkdir -p "$BEAKERLIB_DIR"

    # unless already set by user set global BeakerLib journal and meta file variables
    [ -z "$BEAKERLIB_JOURNAL" ] && export BEAKERLIB_JOURNAL="$BEAKERLIB_DIR/journal.xml"
    [ -z "$BEAKERLIB_METAFILE" ] && export BEAKERLIB_METAFILE="$BEAKERLIB_DIR/journal.meta"

    # creating queue file
    touch $BEAKERLIB_METAFILE

    # make sure the directory is ready, otherwise we cannot continue
    if [ ! -d "$BEAKERLIB_DIR" ] ; then
        echo "rlJournalStart: Failed to create $BEAKERLIB_DIR directory."
        echo "rlJournalStart: Cannot continue, exiting..."
        exit 1
    fi

    # Initialization of variables holding current state of the test
    # TODO: rename to __INTERNAL_
    export INDENT_LEVEL=0
    CURRENT_PHASE_TYPE=()
    CURRENT_PHASE_NAME=()
    export __INTERNAL_PRESISTENT_DATA="$BEAKERLIB_DIR/PersistentData"
    export JOURNAL_OPEN=''
    __INTERNAL_PersistentDataLoad
    export PHASES_FAILED=0
    export TESTS_FAILED=0
    CURRENT_PHASE_TESTS_FAILED=()
    export PHASE_OPENED=0

    if [[ -z "$JOURNAL_OPEN" ]]; then
      # Create Header for XML journal
      rljCreateHeader
      # Create log element for XML journal
      rljWriteToMetafile log
    fi
    JOURNAL_OPEN=1
    # Increase level of indent
    INDENT_LEVEL=1

    # display a warning message if run in POSIX mode
    if [ $POSIXFIXED == "YES" ] ; then
        rlLogWarning "POSIX mode detected and switched off"
        rlLogWarning "Please fix your test to have /bin/bash shebang"
    fi

    # final cleanup file (atomic updates)
    export __INTERNAL_CLEANUP_FINAL="$BEAKERLIB_DIR/cleanup.sh"
    # cleanup "buffer" used for append/prepend
    export __INTERNAL_CLEANUP_BUFF="$BEAKERLIB_DIR/clbuff"

    if touch "$__INTERNAL_CLEANUP_FINAL" "$__INTERNAL_CLEANUP_BUFF"; then
        rlLogDebug "rlJournalStart: Basic cleanup infrastructure successfully initialized"

        if [ -n "$TESTWATCHER_CLPATH" ] && \
           echo "$__INTERNAL_CLEANUP_FINAL" > "$TESTWATCHER_CLPATH"; then
            rlLogDebug "rlJournalStart: Running in test watcher and setup was successful"
            export __INTERNAL_TESTWATCHER_ACTIVE=true
        else
            rlLogDebug "rlJournalStart: Not running in test watcher or setup failed."
        fi
    else
        rlLogError "rlJournalStart: Failed to set up cleanup infrastructure"
    fi
    __INTERNAL_PersistentDataSave
}

# backward compatibility
rlStartJournal() {
    rlJournalStart
    rlLogWarning "rlStartJournal is obsoleted by rlJournalStart"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalEnd
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head3 rlJournalEnd

Summarize the test run and upload the journal file.

    rlJournalEnd

Run on the very end of your script to print summary of the whole test run,
generate OUTPUTFILE and include journal in Beaker logs.

=cut

rlJournalEnd(){
    if [ -z "$__INTERNAL_TESTWATCHER_ACTIVE" ] && [ -s "$__INTERNAL_CLEANUP_FINAL" ] && \
       [ -z "$__INTERNAL_CLEANUP_FROM_JOURNALEND" ]
    then
      rlLogWarning "rlJournalEnd: Not running in test watcher and rlCleanup* functions were used"
      rlLogWarning "rlJournalEnd: Executing prepared cleanup"
      rlLogWarning "rlJournalEnd: Please fix the test to use test watcher"

      # The executed cleanup will always run rlJournalEnd, so we need to prevent
      # infinite recursion. rlJournalEnd runs the cleanup only when
      # __INTERNAL_CLEANUP_FROM_JOURNALEND is not set (see above).
      __INTERNAL_CLEANUP_FROM_JOURNALEND=1 "$__INTERNAL_CLEANUP_FINAL"

      # Return, because the rest of the rlJournalEnd was already run inside the cleanup
      return $?
    fi
    local journal="$BEAKERLIB_JOURNAL"
    local journaltext="$BEAKERLIB_DIR/journal.txt"
    # this should not be needed as the text form should be generated continueousely by rlLogText
    #rlJournalPrintText > $journaltext


    if [ -z "$BEAKERLIB_COMMAND_SUBMIT_LOG" ]
    then
      local BEAKERLIB_COMMAND_SUBMIT_LOG="$__INTERNAL_DEFAULT_SUBMIT_LOG"
    fi

    if [ -n "$TESTID" ] ; then
        $BEAKERLIB_COMMAND_SUBMIT_LOG -T $TESTID -l $journal \
        || rlLogError "rlJournalEnd: Submit wasn't successful"
    else
        rlLogText "JOURNAL META: $BEAKERLIB_METAFILE" LOG
        rlLogText "JOURNAL XML: $journal" LOG
        rlLogText "JOURNAL TXT: $journaltext" LOG
    fi

    echo "#End of metafile" >> $BEAKERLIB_METAFILE
    $__INTERNAL_JOURNALIST --metafile "$BEAKERLIB_METAFILE" --journal "$BEAKERLIB_JOURNAL"

}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalPrint
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head3 rlJournalPrint

Print the content of the journal in pretty xml format.

    rlJournalPrint [type]

=over

=item type

Can be either 'raw' or 'pretty', with the latter as a default.
Raw: xml is in raw form, no indentation etc
Pretty: xml is pretty printed, indented, with one record per line

=back

Example:

    <?xml version="1.0"?>
    <BEAKER_TEST>
      <test_id>debugging</test_id>
      <package>setup</package>
      <pkgdetails>setup-2.8.9-1.fc12.noarch</pkgdetails>
      <starttime>2010-02-08 15:17:47</starttime>
      <endtime>2010-02-08 15:17:47</endtime>
      <testname>/examples/beakerlib/Sanity/simple</testname>
      <release>Fedora release 12 (Constantine)</release>
      <hostname>localhost</hostname>
      <arch>i686</arch>
      <purpose>PURPOSE of /examples/beakerlib/Sanity/simple
        Description: Minimal BeakerLib sanity test
        Author: Petr Splichal &lt;psplicha@redhat.com&gt;

        This is a minimal sanity test for BeakerLib. It contains a single
        phase with a couple of asserts. We Just check that the "setup"
        package is installed and that there is a sane /etc/passwd file.
      </purpose>
      <log>
        <phase endtime="2010-02-08 15:17:47" name="Test" result="PASS"
                score="0" starttime="2010-02-08 15:17:47" type="FAIL">
          <test message="Checking for the presence of setup rpm">PASS</test>
          <test message="File /etc/passwd should exist">PASS</test>
          <test message="File '/etc/passwd' should contain 'root'">PASS</test>
        </phase>
      </log>
    </BEAKER_TEST>

=cut

# cat generated text version
rlJournalPrint(){
    local TYPE=${1:-"pretty"}
    $__INTERNAL_JOURNALIST dump --type "$TYPE"
}

# backward compatibility
rlPrintJournal() {
    rlLogWarning "rlPrintJournal is obsoleted by rlJournalPrint"
    rlJournalPrint
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalPrintText
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head3 rlJournalPrintText

Print the content of the journal in pretty text format.

    rlJournalPrintText [--full-journal]

=over

=item --full-journal

With this option, additional items like some HW information
will be printed in the journal.

=back

Example:

    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    :: [   LOG    ] :: TEST PROTOCOL
    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    :: [   LOG    ] :: Test run ID   : debugging
    :: [   LOG    ] :: Package       : debugging
    :: [   LOG    ] :: Test started  : 2010-02-08 14:45:57
    :: [   LOG    ] :: Test finished : 2010-02-08 14:45:58
    :: [   LOG    ] :: Test name     :
    :: [   LOG    ] :: Distro:       : Fedora release 12 (Constantine)
    :: [   LOG    ] :: Hostname      : localhost
    :: [   LOG    ] :: Architecture  : i686

    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    :: [   LOG    ] :: Test description
    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    PURPOSE of /examples/beakerlib/Sanity/simple
    Description: Minimal BeakerLib sanity test
    Author: Petr Splichal <psplicha@redhat.com>

    This is a minimal sanity test for BeakerLib. It contains a single
    phase with a couple of asserts. We Just check that the "setup"
    package is installed and that there is a sane /etc/passwd file.


    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    :: [   LOG    ] :: Test
    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    :: [   PASS   ] :: Checking for the presence of setup rpm
    :: [   PASS   ] :: File /etc/passwd should exist
    :: [   PASS   ] :: File '/etc/passwd' should contain 'root'
    :: [   LOG    ] :: Duration: 1s
    :: [   LOG    ] :: Assertions: 3 good, 0 bad
    :: [   PASS   ] :: RESULT: Test

=cut
# call rlJournalPrint
rlJournalPrintText(){
    # TODO temporary fix
    rljPrintTestProtocol
    return 0

    local SEVERITY=${LOG_LEVEL:-"INFO"}
    local FULL_JOURNAL=''
    [ "$1" == '--full-journal' ] && FULL_JOURNAL='--full-journal'
    [ "$DEBUG" == 'true' -o "$DEBUG" == '1' ] && SEVERITY="DEBUG"
    #$__INTERNAL_JOURNALIST printlog --severity $SEVERITY $FULL_JOURNAL
}

# TODO_IMP implement with metafile solution
# backward compatibility
rlCreateLogFromJournal(){
    rlLogWarning "rlCreateLogFromJournal is obsoleted by rlJournalPrintText"
    rlJournalPrintText
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlGetTestState
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<=cut
=pod

=head3 rlGetTestState

Returns number of failed asserts in so far, 255 if there are more then 255 failures.
The precise number is set to ECODE variable.

    rlGetTestState
=cut

rlGetTestState(){
    __INTERNAL_PersistentDataLoad
    ECODE=$TESTS_FAILED
    rlLogDebug "rlGetTestState: $ECODE failed assert(s) in test"
    [[ $ECODE -gt 255 ]] && return 255 || return $ECODE
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlGetPhaseState
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<=cut
=pod

=head3 rlGetPhaseState

Returns number of failed asserts in current phase so far, 255 if there are more then 255 failures.
The precise number is set to ECODE variable.

    rlGetPhaseState
=cut

rlGetPhaseState(){
    __INTERNAL_PersistentDataLoad
    ECODE=$CURRENT_PHASE_TESTS_FAILED
    rlLogDebug "rlGetPhaseState: $ECODE failed assert(s) in phase"
    [[ $ECODE -gt 255 ]] && return 255 || return $ECODE
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Internal Stuff
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

rljAddPhase(){
    __INTERNAL_PersistentDataLoad
    local MSG=${2:-"Phase of $1 type"}
    rlLogDebug "rljAddPhase: Phase $MSG started"
    rljWriteToMetafile phase --name "$MSG" --type "$1" >&2
    # Printing
    rljPrintHeadLog "$MSG"

    if [[ -z "$BEAKERLIB_NESTED_PHASES" ]]; then
      INDENT_LEVEL=2
      CURRENT_PHASE_TYPE=( "$1" )
      CURRENT_PHASE_NAME=( "$MSG" )
      CURRENT_PHASE_TESTS_FAILED=( 0 )
      PHASE_OPENED=${#CURRENT_PHASE_NAME[@]}
    else
      let INDENT_LEVEL+=1
      CURRENT_PHASE_TYPE=( "$1" "${CURRENT_PHASE_TYPE[@]}" )
      CURRENT_PHASE_NAME=( "$MSG" "${CURRENT_PHASE_NAME[@]}" )
      CURRENT_PHASE_TESTS_FAILED=( 0 "${CURRENT_PHASE_TESTS_FAILED[@]}" )
      PHASE_OPENED=${#CURRENT_PHASE_NAME[@]}
    fi
    __INTERNAL_PersistentDataSave
}

rljClosePhase(){
    __INTERNAL_PersistentDataLoad
  # TODO: check opened
    local logfile="$BEAKERLIB_DIR/journal.txt"

    local score=$CURRENT_PHASE_TESTS_FAILED
    # Result
    if [ $CURRENT_PHASE_TESTS_FAILED -eq 0 ]; then
        result="PASS"
    else
        result="$CURRENT_PHASE_TYPE"
        let PHASES_FAILED+=1
    fi

    local name="$CURRENT_PHASE_NAME"

    rlLogDebug "rljClosePhase: Phase $name closed"
    #rlJournalPrintText > $logfile
    logfile=""  # TODO_IMP implement creation of logfile!
    rlReport "$name" "$result" "$score" "$logfile"

    # Reset of state variables
    if [[ -z "$BEAKERLIB_NESTED_PHASES" ]]; then
      INDENT_LEVEL=1
      CURRENT_PHASE_TYPE=()
      CURRENT_PHASE_NAME=()
      CURRENT_PHASE_TESTS_FAILED=()
    else
      let INDENT_LEVEL-=1
      unset CURRENT_PHASE_TYPE[0]; CURRENT_PHASE_TYPE=( "${CURRENT_PHASE_TYPE[@]}" )
      unset CURRENT_PHASE_NAME[0]; CURRENT_PHASE_NAME=( "${CURRENT_PHASE_NAME[@]}" )
      [[ ${#CURRENT_PHASE_TESTS_FAILED[@]} -gt 1 ]] && let CURRENT_PHASE_TESTS_FAILED[1]+=CURRENT_PHASE_TESTS_FAILED[0]
      unset CURRENT_PHASE_TESTS_FAILED[0]; CURRENT_PHASE_TESTS_FAILED=( "${CURRENT_PHASE_TESTS_FAILED[@]}" )
    fi
    PHASE_OPENED=${#CURRENT_PHASE_NAME[@]}
    # Updating phase element
    rljWriteToMetafile --result "$result" --score "$score"
    __INTERNAL_PersistentDataSave
}

# $1 message
# $2 result
# $3 command
rljAddTest(){
    __INTERNAL_PersistentDataLoad
    if [ $PHASE_OPENED -eq 0 ]; then
        rljAddPhase "FAIL" "Asserts collected outside of a phase"
        rljWriteToMetafile test --message "TEST BUG: Assertion not in phase" -- "FAIL" >&2
        rlLogText "TEST BUG: Assertion not in phase" "FAIL"
        rljWriteToMetafile test --message "$1" -- "$2" >&2
        rlLogText "$1" "$2"
        rljClosePhase
        let TESTS_FAILED+=1
        let CURRENT_PHASE_TESTS_FAILED+=1
    else
        rljWriteToMetafile test --message "$1" ${3:+--command "$3"} -- "$2" >&2
        if [ "$2" != "PASS" ]; then
            let TESTS_FAILED+=1
            let CURRENT_PHASE_TESTS_FAILED+=1
        fi
    fi
    __INTERNAL_PersistentDataSave
}

rljAddMetric(){
    local MID="$2"
    local VALUE="$3"
    local TOLERANCE=${4:-"0.2"}
    if [ "$MID" == "" ] || [ "$VALUE" == "" ]
    then
        rlLogError "TEST BUG: Bad call of rlLogMetric"
        return 1
    fi
    rlLogDebug "rljAddMetric: Storing metric $MID with value $VALUE and tolerance $TOLERANCE"
    rljWriteToMetafile metric --type "$1" --name "$MID" \
        --value="$VALUE" --tolerance="$TOLERANCE" >&2
    return $?
}

rljAddMessage(){
    rljWriteToMetafile message --message "$1" --severity "$2" >&2
}

rljRpmLog(){
    #rljWriteToMetafile rpm --package "$1" >&2

    # TODO probably runs again pointlessly, it should be enough to have it run in header-creation and save it into global
    package="$1"
    # MEETING Anyway, is this needed at all? Why does every phase have pkgdetails again when it is in the header?
    # Write package details (rpm, srcrpm) into metafile
    rljGetPackageDetails $package
}


# TODO comment
rljGetRPM() {
    rpm=$(rpm -q $1)
    [ $? -ne 0 ] && return 1 # TODO_IMP doesn't work, returns 0 no matter what
    echo "$rpm"
    return 0
}

# TODO comment
rljGetSRCRPM() {
    srcrpm=$(rpm -q $1 --qf '%{SOURCERPM}')
    [ $? -ne 0 ] && return 1
    echo "$srcrpm"
    return 0
}

# TODO comment
# TODO: rename funtion to match what it actually does
# TODO: should be intrenal, maybe replaced bu __INTERNAL_rpmGetPackageInfo
rljGetPackageDetails(){
    # RPM and SRCRPM version of the package
    if [ "$1" != "unknown" ]; then
        rpm=$(rljGetRPM $1)
        if [ $? -ne 0 ]; then
            rljWriteToMetafile pkgnotinstalled -- "$1"
        else
            srcrpm=$(rljGetSRCRPM $1)
            rljWriteToMetafile pkgdetails --sourcerpm "$srcrpm" -- "$rpm"
        fi
    fi
    return 0
}

# TODO comment
# TODO: rename to _INTERNAL_
rljDeterminePackage(){
    if [ "$PACKAGE" == "" ]; then
        if [ "$TEST" == "" ]; then
            package="unknown"
        else
            arrPac=(${TEST//// })
            package=${arrPac[1]}
        fi
    else
        package="$PACKAGE"
    fi
    echo "$package"
    return 0
}

# MEETING check logic of individual operations
# MEETING rename all vars to BEAKERLIB_... to prevent overwriting them in test?
# MEETING (they are used later in creating TEST PROTOCOL)
# Creates header
rljCreateHeader(){

    # Determine package which is tested
    package=$(rljDeterminePackage)
    rljWriteToMetafile package -- "$package"

    # Write package details (rpm, srcrpm) into metafile
    rljGetPackageDetails $package

    # RPM version of beakerlib
    beakerlib_rpm=$(rljGetRPM beakerlib)
    [ $? -eq 0 ] && rljWriteToMetafile beakerlib_rpm -- "$beakerlib_rpm"

    # RPM version of beakerlib-redhat
    beakerlib_redhat_rpm=$(rljGetRPM beakerlib-redhat)
    [ $? -eq 0 ] && rljWriteToMetafile beakerlib_redhat_rpm -- "$beakerlib_redhat_rpm"


    # Starttime and endtime
    rljWriteToMetafile starttime
    rljWriteToMetafile endtime

    # Test name
    [ "$TEST" == ""  ] && TEST="unknown"
    rljWriteToMetafile testname -- "$TEST"

    # OS release
    release=$(cat /etc/redhat-release)
    [ "$release" != "" ] && rljWriteToMetafile release -- "$release"

    # Hostname # MEETING is there a better way?
    hostname=$(python -c 'import socket; print(socket.getfqdn())')
    [ "$hostname" != "" ] && rljWriteToMetafile hostname -- "$hostname"

    # Architecture # MEETING is it the correct way?
    arch=$(arch)
    [ "$arch" != "" ] && rljWriteToMetafile arch -- "$arch"

    # CPU info
    if [ -f "/proc/cpuinfo" ]; then
        count=0
        type=""
        cpu_regex="^model\sname.*: (.*)$"
        while read line; do
            if [[ "$line" =~ $cpu_regex ]]; then    # MEETING bash construct, is it ok?
                type="${BASH_REMATCH[1]}"
                let count++
            fi
        done < "/proc/cpuinfo"
        rljWriteToMetafile hw_cpu -- "$count x $type"
    fi

    # RAM size
     if [ -f "/proc/meminfo" ]; then
        size=0
        ram_regex="^MemTotal: *(.*) kB$"
        while read line; do
            if [[ "$line" =~ $ram_regex ]]; then   # MEETING bash construct, is it ok?
                size=`expr ${BASH_REMATCH[1]} / 1024`
                break
            fi
        done < "/proc/meminfo"
        rljWriteToMetafile hw_ram -- "$size MB"
    fi

    # HDD size
    size=0
    hdd_regex="^(/[^ ]+) +([0-9]+) +[0-9]+ +[0-9]+ +[0-9]+% +[^ ]+$"
    while read -r line ; do
        if [[ "$line" =~ $hdd_regex ]]; then   # MEETING bash construct, is it ok?
            let "size=size+${BASH_REMATCH[2]}"
         fi
    done < <(df -k -P --local --exclude-type=tmpfs)
    [ "$size" -ne 0 ] && rljWriteToMetafile hw_hdd -- "$(echo "scale=2;$size/1024/1024" | bc) GB"

    # Purpose
    purpose=""
    [ -f 'PURPOSE' ] && purpose=$(cat PURPOSE)
    rljWriteToMetafile purpose -- "$purpose"

    return 0
}


__INTERNAL_jHash() {
  echo -n "$1" | base64 -w 0
}


# Encode arguments' values into base64
# Adds --timestamp argument and indent
# writes it into metafile
# takes [element] --attribute1 value1 --attribute2 value2 .. [-- "content"]
rljWriteToMetafile(){
    local timestamp indent
    printf -v timestamp '%(%s)T' -1
    local line=""
    local lineraw=''
    local ARGS=("$@")
    #set | grep ^ARGS=
    local element=''

    [[ "${1:0:2}" != "--" ]] && {
      local element="$1"
      shift
    }
    local arg
    while [[ $# -gt 0 ]]; do
      #echo "$1"
      case $1 in
      --)
        line+=" -- \"$(echo -n "$2" | base64 -w 0)\""
        lineraw+=" -- \"$2\""
        shift 2
        break
        ;;
      --*)
        line+=" $1=\"$(echo -n "$2" | base64 -w 0)\""
        lineraw+=" $1=\"$2\""
        shift
        ;;
      *)
        rlLogText "unexpected meta input format"
        set | grep ^ARGS=
        exit 124
        ;;
      esac
      shift
    done
    [[ $# -gt 0 ]] && {
      rlLogText "unexpected meta input format"
      set | grep ^ARGS=
      exit 125
    }

    printf -v indent '%*s' $INDENT_LEVEL

    line="$indent${element:+$element }--timestamp=\"$timestamp\"$line"
    lineraw="$indent${element:+$element }--timestamp=\"$timestamp\"$lineraw"
    #echo "#${lineraw:1}" >&2
    #echo "#${lineraw:1}" >> $BEAKERLIB_METAFILE
    echo "$line" >> $BEAKERLIB_METAFILE
}

rljPrintHeadLog(){
    rlLogText "\n::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    rlLogText "$1" LOG
    rlLogText "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::\n"
}

# TODO: will be completely rewritten using coninueously generated log file
rljPrintTestProtocol(){
    rljPrintHeadLog "TEST PROTOCOL"
    rlLogText "Package       : $package"
    rlLogText "Installed     : $(rljGetRPM "$package")"
    rlLogText "beakerlib RPM : $beakerlib_rpm"
    rlLogText "bl-redhat RPM : $beakerlib_redhat_rpm"

    STARTTIME=""
    ENDTIME=""
    # MEETING What if metafile will be too big? Isn't it better to read it directly from file in loop bellow?
    # MEETING ...might be slower but more reliable
    metafile=$(cat "$BEAKERLIB_METAFILE")

    # Getting first and last timestamp from metafile
    #while read -r line
    #do
    #    if [[ "$line" =~ --timestamp=\"(.*)\" ]]; then
    #        if [ "$STARTTIME" == "" ]; then
    #            STARTTIME="${BASH_REMATCH[1]}"
    #        fi
    #        ENDTIME="${BASH_REMATCH[1]}"
    #    fi
    #done < <(echo "$metafile")

    STARTTIME=$(date -d "@$STARTTIME" '+%Y-%m-%d %H:%M:%S %Z')
    ENDTIME=$(date -d "@$ENDTIME" '+%Y-%m-%d %H:%M:%S %Z')

    rlLogText "Test started  : $STARTTIME"
    rlLogText "Test finished : $ENDTIME"
    rlLogText "Test name     : $TEST"
    rlLogText "Distro        : $release"
    rlLogText "Hostname      : $hostname"
    rlLogText "Architecture  : $arch"

    rljPrintHeadLog "Test description"
    echo "$purpose"

}

__INTERNAL_PersistentDataSave() {
  cat > "$__INTERNAL_PRESISTENT_DATA" <<EOF
TESTS_FAILED=$TESTS_FAILED
PHASES_FAILED=$PHASES_FAILED
JOURNAL_OPEN=$JOURNAL_OPEN
EOF
declare -p CURRENT_PHASE_TESTS_FAILED >> $__INTERNAL_PRESISTENT_DATA
}

__INTERNAL_PersistentDataLoad() {
  [[ -r "$__INTERNAL_PRESISTENT_DATA" ]] && . "$__INTERNAL_PRESISTENT_DATA"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# AUTHORS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head1 AUTHORS

=over

=item *

Petr Muller <pmuller@redhat.com>

=item *

Jan Hutar <jhutar@redhat.com>

=item *

Ales Zelinka <azelinka@redhat.com>

=item *

Petr Splichal <psplicha@redhat.com>

=back

=cut
