#!/usr/perl5/bin/perl -w
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
# Copyright (c) 2011 Joyent, Inc.
#
# vfsstat - report VFS statistics per zone
#
# USAGE:    vfsstat [-hIMrZ] [interval [count]]
#           -h              # help
#	    -I              # print results per interval (where applicable)
#	    -M              # print results in MB/s
#	    -r		    # print data in comma-separated format
#	    -Z		    # print data for all zones
#
#   eg,	    vfsstat               # print summary since zone boot
#           vfsstat 1             # print continually every 1 second
#           vfsstat 1 5           # print 5 times, every 1 second
#
# NOTES:
#
# - The calculations and output fields emulate those from iostat(1M) as closely
#   as possible.  When only one zone is actively performing disk I/O, the
#   results from iostat(1M) in the global zone and vfsstat in the local zone
#   should be almost identical.  Note that many VFS read operations are handled
#   by the ARC, so vfsstat and iostat(1M) will be similar only when most
#   requests are missing in the ARC.
#
# - As with iostat(1M), a result of 100% for VFS read and write utilization does
#   not mean that the syscall layer is fully saturated.  Instead, that
#   measurement just shows that at least one operation was pending over the last
#   quanta of time examined.  Since the VFS layer can process more than one
#   operation concurrently, this measurement will frequently be 100% but the VFS
#   layer can still accept additional requests.
#
# - This script is based on Brendan Gregg's K9Toolkit examples:
#
#	http://www.brendangregg.com/k9toolkit.html
#

use Getopt::Std;
use Sun::Solaris::Kstat;
my $Kstat = Sun::Solaris::Kstat->new();

# Process command line args
usage() if defined $ARGV[0] and $ARGV[0] eq "--help";
getopts('hIMrZ') or usage();
usage() if defined $main::opt_h;
$main::opt_h = 0;

my $USE_MB = defined $main::opt_M ? $main::opt_M : 0;
my $USE_INTERVAL = defined $main::opt_I ? $main::opt_I : 0;
my $USE_COMMA = defined $main::opt_r ? $main::opt_r : 0;
my $ALL_ZONES = defined $main::opt_Z ? $main::opt_Z : 0;

my ($interval, $count);
if ( defined($ARGV[0]) ) {
	$interval = $ARGV[0];
	$count = defined ($ARGV[1]) ? $ARGV[1] : 2**32;
	usage() if ($interval == 0);
} else {
	$interval = 1;
	$count = 1; 
}

my $HEADER_FMT = $USE_COMMA ?
    "r/%s,w/%s,%sr/%s,%sw/%s,wait_t,ractv,wactv,read_t,writ_t,%%r,%%w,zone\n" :
    "   r/%s    w/%s   %sr/%s   %sw/%s wait_t ractv wactv " .
    "read_t writ_t  %%r  %%w zone\n";
my $DATA_FMT = $USE_COMMA ?
    "%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%d,%s\n" :
    "%6.1f %6.1f %6.1f %6.1f %6.1f %5.1f %5.1f %6.1f %6.1f %3d %3d %s\n";

my $BYTES_PREFIX = $USE_MB ? "M" : "k";
my $BYTES_DIVISOR = $USE_MB ? 1024 * 1024 : 1024;
my $INTERVAL_SUFFIX = $USE_INTERVAL ? "i" : "s";

my @fields = ( 'reads', 'writes', 'nread', 'nwritten', 'rtime', 'wtime',
    'rlentime', 'wlentime', 'snaptime' );

chomp(my $curzone = (`/sbin/zonename`));

# Read list of visible zones and their zone IDs
my @zones = ();
my %zoneids = ();
my $zoneadm = `zoneadm list -p | cut -d: -f1,2`;
@lines = split(/\n/, $zoneadm);
foreach $line (@lines) {
	@tok = split(/:/, $line);
	$zoneids->{$tok[1]} = $tok[0];
	push(@zones, $tok[1]);
}

my %old = ();

$Kstat->update();

for (my $ii = 0; $ii < $count; $ii++) {
	printf($HEADER_FMT, $INTERVAL_SUFFIX, $INTERVAL_SUFFIX, $BYTES_PREFIX,
	    $INTERVAL_SUFFIX, $BYTES_PREFIX, $INTERVAL_SUFFIX);

	foreach $zone (@zones) {
		if ((!$ALL_ZONES) && ($zone ne $curzone)) {
			next;
		}

		if (! defined $old->{$zone}) {
			$old->{$zone} = ();
			foreach $field (@fields) { $old->{$zone}->{$field} = 0; }
		}

		my $zoneid = $zoneids->{$zone};
		print_stats($zone, $Kstat->{'zone_vfs'}{$zoneid}{$zone},
		    $old->{$zone});
	}

	sleep ($interval);
	$Kstat->update();
}

exit(0);

sub print_stats {
	my $zone = $_[0];
	my $data = $_[1];
	my $old = $_[2];

	my $etime = $data->{'snaptime'} -
	    ($old->{'snaptime'} > 0 ? $old->{'snaptime'} : $data->{'crtime'});

	# Calculate basic statistics
	my $rate_divisor = $USE_INTERVAL ? 1 : $etime;
	my $reads = ($data->{'reads'} - $old->{'reads'}) / $rate_divisor;
	my $writes = ($data->{'writes'} - $old->{'writes'}) / $rate_divisor;
	my $nread = ($data->{'nread'} - $old->{'nread'}) /
	    $rate_divisor / $BYTES_DIVISOR;
	my $nwritten = ($data->{'nwritten'} - $old->{'nwritten'}) /
	    $rate_divisor / $BYTES_DIVISOR;
	
	# XXX Need to investigate how to calculate this
	my $wait_t = 0.0;

	# Calculate transactions per second
	my $r_tps = ($data->{'reads'} - $old->{'reads'}) / $etime;
	my $w_tps = ($data->{'writes'} - $old->{'writes'}) / $etime;

	# Calculate average length of active queue
	my $r_actv = ($data->{'rlentime'} - $old->{'rlentime'}) / $etime;
	my $w_actv = ($data->{'wlentime'} - $old->{'wlentime'}) / $etime;

	# Calculate average service time
	my $read_t = $r_tps > 0 ? $r_actv * (1000 / $r_tps) : 0.0;
	my $writ_t = $w_tps > 0 ? $w_actv * (1000 / $w_tps) : 0.0;

	# Calculate the % time the VFS layer is active
	my $r_b_pct = (($data->{'rtime'} - $old->{'rtime'}) / $etime) * 100;
	my $w_b_pct = (($data->{'wtime'} - $old->{'wtime'}) / $etime) * 100;

	printf($DATA_FMT, $reads, $writes, $nread, $nwritten, $wait_t,
	    $r_actv, $w_actv, $read_t, $writ_t, $r_b_pct, $w_b_pct, $zone);

	# Save current calculations for next loop
	foreach (@fields) { $old->{$_} = $data->{$_}; }
}

sub usage {
        print STDERR <<END;
USAGE: vfsstat [-hIMrZ] [interval [count]]
   eg, vfsstat               # print summary since zone boot
       vfsstat 1             # print continually every 1 second
       vfsstat 1 5           # print 5 times, every 1 second
       vfsstat -I            # print results per interval (where applicable)
       vfsstat -M            # print results in MB/s
       vfsstat -r            # print results in comma-separated format
       vfsstat -Z            # print results for all zones
END
        exit 1;
}
