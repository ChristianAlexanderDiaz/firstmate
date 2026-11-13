#!/usr/bin/env perl
# Blocking idle waits for the supervision host and process-event lease guard.
# Usage: fm-idle-wait.pl arm PID SECONDS STATE [TEST-CLOCK]
#        fm-idle-wait.pl lease PID STATE DEVICE INODE LEASE-PATH AGE HALF-TICK IDENTITY MISSES
# Returns 0 on process exit, 1 at the arm deadline or after two lease misses.
# This observer never signals a process. The shell owner re-verifies identity
# and process-group ownership before any cleanup. Perl is already required by
# both callers. Arm waits and /proc lease checks spawn no recurring children;
# BSD lease checks retain one direct ps child for the runner identity proof.
use strict;
use warnings;
use Cwd qw(abs_path);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
my ($mode, $pid, @args) = @ARGV;
defined($pid) && $pid =~ /\A[1-9][0-9]*\z/ or die "invalid wait pid\n";
my $parent = getppid();
sub alive { kill(0, $_[0]) || $!{EPERM} }
sub identity {
    my ($id) = @_;
    my $proc = $ENV{FM_PROC_ROOT_OVERRIDE} // '/proc';
    if (-r "$proc/$id/stat" && -r "$proc/$id/cmdline") {
        open(my $stat, '<', "$proc/$id/stat") or return;
        my $line = <$stat> // '';
        $line =~ s/.*\)//;
        my @fields = split ' ', $line;
        return unless @fields >= 20 && $fields[19] =~ /\A[0-9]+\z/;
        open(my $cmd, '<', "$proc/$id/cmdline") or return;
        local $/;
        my $bytes = <$cmd>;
        return unless defined($bytes) && length($bytes);
        my $key = $^O eq 'linux' ? 'linux-starttime' : 'proc-starttime';
        return "$key=$fields[19] cmdline-hex=" . unpack('H*', $bytes);
    }
    # BSD has no /proc. One direct ps child retains fm_pid_identity's complete
    # start-time/command proof without a shell, sed, or command substitutions.
    local $ENV{LC_ALL} = 'C';
    local $ENV{COLUMNS} = 10000;
    open(my $ps, '-|', 'ps', '-p', $id, '-o', 'lstart=', '-o', 'command=') or return;
    local $/;
    my $value = <$ps> // '';
    close($ps) or return;
    $value =~ s/^[[:space:]]*//mg;
    $value =~ s/\n+\z//;
    return length($value) ? $value : undef;
}
sub asleep {
    my ($state) = @_;
    return 1 if -e "$state/.sleep" || -e "$state/.sleep-return";
    return asleep($1) if $state =~ m{\A(.*)/parent-route\z};
    return 0;
}
if ($mode eq 'arm') {
    my ($seconds, $state, $clock) = @args;
    my $started = clock_gettime(CLOCK_MONOTONIC);
    while (alive($parent) && alive($pid)) {
        my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $started;
        if (defined($clock) && length($clock)) {
            $elapsed = 0;
            if (open(my $in, '<', $clock)) {
                my $value = <$in> // '';
                $elapsed = $value if $value =~ /\A[1-9][0-9]*\s*\z/;
            }
        }
        exit 1 if $elapsed >= $seconds && !asleep($state);
        sleep 0.5;
    }
    exit 0;
}
if ($mode eq 'lease') {
    my ($state, $device, $inode, $lease, $age, $half, $expected, $misses) = @args;
    $misses //= 0;
    while (alive($parent) && alive($pid)) {
        sleep $half;
        exit 0 unless alive($parent) && alive($pid);
        my $actual = identity($pid);
        next unless defined($actual);
        exit 0 unless $actual eq $expected;
        my $canonical = abs_path($state);
        my @root = defined($canonical) ? stat($canonical) : ();
        my $valid = @root && $canonical !~ /[[:cntrl:]]/ && -d _ && $root[4] == $> && !($root[2] & 0022)
            && $root[0] == $device && $root[1] == $inode;
        # The integration fixture injects one failed read after readiness,
        # leaving startup validation and every later observation unchanged.
        if (($ENV{FM_TEST_SEAM} // '') eq '1' && $ENV{FM_TEST_LEASE_FAIL_ONCE_DIR}) {
            my $fixture = $ENV{FM_TEST_LEASE_FAIL_ONCE_DIR};
            if (-s "$fixture/armed" && !-s "$fixture/spent") {
                open(my $spent, '>', "$fixture/spent") or die "lease injection: $!\n";
                print {$spent} "spent\n";
                close($spent) or die "lease injection: $!\n";
                $valid = 0;
            }
        }
        my $fresh = 0;
        if ($valid && -f $lease && !-l $lease && open(my $in, '<', $lease)) {
            my $started = clock_gettime(CLOCK_MONOTONIC);
            my $value = <$in> // '';
            if ($value =~ /\A([0-9]+(?:\.[0-9]+)?)\n\z/) {
                my $reference = $1;
                my $finished = clock_gettime(CLOCK_MONOTONIC);
                my $elapsed = $finished - $reference;
                $fresh = $elapsed >= 0 && int($elapsed) <= $age;
                # The integration timing proof records actual observations,
                # including their phase relative to expiry, without a clock fake.
                if (($ENV{FM_TEST_SEAM} // '') eq '1' && $ENV{FM_TEST_LEASE_READ_LOG}) {
                    open(my $log, '>>', $ENV{FM_TEST_LEASE_READ_LOG}) or die "lease observation: $!\n";
                    print {$log} join("\t", $started, $finished, int($elapsed), $reference), "\n";
                    close($log) or die "lease observation: $!\n";
                }
            }
        }
        $misses = $fresh ? 0 : $misses + 1;
        exit 1 if $misses >= 2;
    }
    exit 0;
}
die "unknown wait mode\n";
