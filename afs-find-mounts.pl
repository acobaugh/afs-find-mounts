#!/usr/bin/perl

# $Id$

use strict;
use File::Find;
use File::Basename;
use Cwd;
use String::ShellQuote;
use Getopt::Long;

Getopt::Long::Configure('bundling');

my ($opt_verbose, $opt_quiet, $opt_byvolume, $opt_bymount, $opt_help);

GetOptions(
	'h|help' => \$opt_help,
	'v|verbose' => \$opt_verbose,
	'q|quiet' => \$opt_quiet,
	'l|by-volume' => \$opt_byvolume,
	'm|by-mount' => \$opt_bymount
);

if ($opt_help) {
	exec('perldoc', '-t', $0) or die "Cannot feed myself to perldoc\n";
	exit 0;
} elsif ($#ARGV eq -1) {
	print "Usage: $0 [-h|--help] [-v|--verbose] [-q|--quiet] [-l|--by-volume] [-m|--by-mount] PATH [OUTFILE_BASE]\n";
	exit 0;
}

if ($opt_byvolume ne 1 and $opt_bymount ne 1) {
	print "You must specify how to display the results with either -l|--by-volume or -m|--by-mount\n";
	exit 0;
}

my $fs_cmd = '/usr/bin/fs';

my ($volname, %volmounts, %volstack, %mountpoints, $output_to_file, $outfile_base);

my $path = $ARGV[0];
my $cwd = cwd();
if ($path !~ m/^\//) {
	# if path is not absolute
	$path = $cwd . $path
}

if ($ARGV[1] ne "") {
	$output_to_file = 1;
	$outfile_base = $ARGV[1];
}

# strip tailing '/' from given path
$path =~ s/\/$//;

my $wscell = `fs wscell 2>&1`;
$wscell =~ s/.*'(.*)'\n/$1/;

if (!$opt_quiet) {
	print "My cell: $wscell\n";
	print "Walking  $path\n\n";
}

# find the mount point for the volume containing $path
# this basically is a single-step version of walkdir()
my $newpath = $path;
while (!examine_dir($newpath)) {
	$newpath = dirname($newpath);
}
my ($volume, $type, $mtptcell) = examine_dir($newpath);
# store this mountpoint and mtpt type for $volume
$volmounts{$volume}{'cell'} = $mtptcell;
$volmounts{$volume}{'mounts'}{$newpath} = $type; # add a mountpoint for this volume
# store this volume, cell, and type for this mtpt
$mountpoints{$newpath} = {'volume' => $volume, 'cell' => $mtptcell, 'type' => $type};
$volstack{$volume} = 1; # make it known that we hit $volname on this dive

&walkdir($path, \%volstack);

if ($opt_byvolume) {
	if ($output_to_file) {
		open OUTFILE, ">$outfile_base-by-volume";
	} else {
		open OUTFILE, ">&STDOUT";
	}
	# print mountpoints by volume
	foreach $volname (sort keys %volmounts) {
		print OUTFILE "$volname|$volmounts{$volname}{'cell'}\n";
		foreach my $mountpoint (sort keys %{$volmounts{$volname}{'mounts'}})	{
			print OUTFILE "\t$volmounts{$volname}{'mounts'}{$mountpoint} $mountpoint\n";
		}
		print OUTFILE "\n";
	}
	close OUTFILE;
}

if ($opt_bymount) {
	if ($output_to_file) {
		open OUTFILE, ">$outfile_base-by-mount";
	} else {
		open OUTFILE, ">&STDOUT";
	}
	# print mountpoints by mountpoint
	foreach my $mntpt (sort keys %mountpoints) {
		print OUTFILE $mntpt . "|" 
		. $mountpoints{$mntpt}{'type'} . "|" 
		. $mountpoints{$mntpt}{'volume'} . "|"
		. $mountpoints{$mntpt}{'cell'} . "\n";
	}
	close OUTFILE;
}

# do stuff for every directory in a given directory
sub walkdir {
	my $path = $_[0];
	my %volstack = %{$_[1]};
	my (@entries, $entry, $entry_relative);

	opendir(DIR, $path);
	@entries = readdir(DIR);
	closedir(DIR);

	# this gets every entry underneath
	foreach $entry (@entries) {
		if ($entry ne "." and $entry ne "..") {
			$entry = $path . "/" . $entry;
			if ( -d $entry and ! -l $entry) {
				print "Processing $entry as a directory" if $opt_verbose;
				&processdir($entry, \%volstack);	
			} else {
				print "$entry is not a directory\n" if $opt_verbose;
			}
		}
	}
}

sub processdir {
	my $dir = shell_quote($_[0]);
	my %volstack = %{$_[1]};
	#print "processing $dir\n";

	my ($volume, $type, $mtptcell) = examine_dir($dir);
	if ($volume ne 0) {
		# store this mountpoint and mtpt type for $volume
		$volmounts{$volume}{'cell'} = $mtptcell;
		$volmounts{$volume}{'mounts'}{$dir} = $type; # add a mountpoint for this volume

		# store this volume, cell, and type for this mtpt
		$mountpoints{$dir} = {'volume' => $volume, 'cell' => $mtptcell, 'type' => $type};
		
		# dont't go down if:
		if ($volstack{$volume} != 1 # we're not already in this volume
				and $mtptcell eq $wscell # volume is in our cell
				and $volume !~ m/.+.backup$/ # not a backup volume
				and ! defined $volmounts{$volume}{$dir} # haven't already walked this volume
		) {
			print "\%volstack is:\n";
			foreach (keys %volstack) {
				print "$_\n";
			}
			print "\n";
			$volstack{$volume} = 1; # make it known that we hit $volname on this dive
			&walkdir($dir, \%volstack);
			#print "going into $dir";
		}
	}
	else { 
		# it's not a mountpoint, but we still need to go into it
		&walkdir($dir, \%volstack);
	}
}

sub examine_dir {
	my ($dir) = @_;
	
	my $lsmount = `$fs_cmd lsmount $dir 2>&1`;
	if ($lsmount =~ m/.*is a mount point.*/) {
		$lsmount =~ s/.*is a mount point for volume '(.+)'\n/$1/;
		$lsmount =~ s/(.+)(:.*)/$1/;
		my $mtptcell = $2;
		
		if ($mtptcell eq "")	{
			$mtptcell = $wscell;
		} else {
			$mtptcell =~ s/://;
		}

		$lsmount =~ m/(%|#)(.+)/;
		my $type = $1;
		my $volume = $2;

		return ($volume, $type, $mtptcell);
	}
	else {
		return (0, 0, 0);
	}
}

__END__

=head1 NAME

afs-find-mounts.pl - finds all AFS mount points under a given path, and prints the results by-volume or by-path

=head1 SYNOPSIS

 afs-find-mounts.pl [-h|--help] [-v|--verbose] [-q|--quiet] [-l|--by-volume] [-m|--by-mount] PATH

=head1 OPTIONS

=over 8

=item B<-h>, B<help>

Print this documentation

=item B<-v>, B<--verbose>

Say what we're doing at each step of the process

=item B<-q>, B<--quiet>

Only print the mounts by mount or by volume with no processing information. NOT mutually exclusive with --verbose

=item B<-l>, B<--by-volume>

Print mount points by volume name

=item B<-m>, B<--by-mount>

Print mount points by mount point path

=item B<PATH>

Path to dive into. This can either be relative or absolute. 

=cut
