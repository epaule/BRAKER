#!/usr/bin/perl

####################################################################################################
#                                                                                                  #
# align2hints.pl - generate hints from spaln [O0 (=gff3)], exonerate, genomeThreader (gth)         #
#                  or scipio output                                                                #
#                                                                                                  #
# Authors: Simone Lange, Mario Stanke                                                              #
#                                                                                                  #
# Contact: mario.stanke@uni-greifswald.de                                                          #
#                                                                                                  #
# Release date: November 12th 2015                                                                 #
#                                                                                                  #
# This script is under the Artistic Licence                                                        #
# (http://www.opensource.org/licenses/artistic-license.php)                                        #
#                                                                                                  #
# Usage:                                                                                           #
# align2hints.pl [OPTIONS] --in=align.gff3 --out=hintsfile.gff --prg=gth|exonerate|spaln|scipio    #
#                                                                                                  #
####################################################################################################

use strict;
use warnings;
use Getopt::Long;
use File::Spec::Functions qw(rel2abs);
use Cwd;

my $usage = <<'ENDUSAGE';

align2hints.pl   generate hints from spaln [O0 (=gff3)], exonerate, genomeThreader (gth) or scipio
                 output.
                 Spaln2 run like this: spaln -O0 ... > spalnfile
                 Exonerate run like this: exonerate --model protein2genome --showtargetgff T ... > exfile
                 GenomeThreader run like this: gth -genomic genome.fa  -protein protein.fa -gff3out 
                                               -skipalignmentout ... -o gthfile
                 scipio run like this:
                 scipio.1.4.1.pl genome.fa prot.fa | yaml2gff.1.4.pl > scipio.gff

SYNOPSIS

align2hints.pl [OPTIONS] --in=align.gff3 --out=hintsfile.gff --prg=gth|exonerate|spaln|scipio

  --in                 input file from gth (gff3), spaln (gff3) or exonerate output  
  --out                contains CDSpart, CDS and intron hints


OPTIONS

    --help                   Print this help message.
    --CDSpart_cutoff=n       This many bp are cut off of each CDSpart hint w.r.t. the cds (default 15).
    --maxintronlen=n         Alignments with longer gaps are discarded (default 350000).
    --minintronlen=n         Alignments with gaps shorter than this and longer than maxgaplen are discarded (default 41).
    --priority=n             Priority of hint group (default 4).
    --prg=s                  Alignment program of input file, either 'gth', 'spaln', 'exonerate', or 'scipio'.
    --source=s               Source identifier (default 'P')


Format:
  seqname <TAB> source <TAB> feature <TAB> start <TAB> end <TAB> score <TAB> strand <TAB> frame <TAB> src=source;grp=target_protein;pri=priority


DESCRIPTION

  Example:

    align2hints.pl [OPTIONS] --in=align.gff3 --out=hintsfile.gff --prg=gth

ENDUSAGE


my $alignfile;                    # alignment input file
my $CDSpart_cutoff = 15;          # cutoff for CDSpart hints
my $CDSpartid = "CDSpart";        # abbreviate to decrease file size
my $dir;                          # working superdirectory where programme is called from
my $hintsfilename;                # hints file output name
my $intron_end;                   # end of intron (only for gth and spaln)
my $intron_score;                 # intron score
my $intron_start;                 # start of intron (only for gth and spaln)
my $intron_threshold;             # Threshold for current programme
my $intron_threshold_gth = 0.7;   # introns from gth with a score below this are discarded
my $intron_threshold_spn = 200; # introns from spaln with a score below this are discarded
my $maxintronlen = 350000;        # maximal intron length
my $minintronlen = 41;            # default minimal intron length
my $parent;                       # current parent
my $prevParent = "noP";           # previous parent
my $prevScore = 0;                # previous exon/CDS score for calculating intron score
my ($qstart, $qend, $prevQend);   # positions in query protein (scipio only), to determine intron for scipio
my $prgsrc;                       # source programme (exonerate, spaln or gth)
my $priority = 4;                 # priority for hints
my $source = "P";                 # source for extrinsic file



if($#ARGV < 1){
  print "$usage";
  exit;
}

GetOptions('in=s'             => \$alignfile,
           'out=s'            => \$hintsfilename,
           'CDSpart_cutoff:i' => \$CDSpart_cutoff,
           'dir=s'            => \$dir,
           'maxintronlen:i'   => \$maxintronlen,
           'minintronlen:i'   => \$minintronlen,
           'priority:i'       => \$priority,
           'prg=s'            => \$prgsrc,
           'source:s'         => \$source);

# mainly for usage within BRAKER2
if(!defined($dir)){
    $dir = cwd();
}
my $last_char = substr($dir, -1);
if($last_char eq "\/"){
    chop($dir);
}


if (defined($alignfile)){
    # check whether alignment file exists
    if(! -e $alignfile){
        print STDERR "ERROR: Alignment file $alignfile does not exist. Please check.\n";
        exit(1);
    } else {
        $alignfile = rel2abs($alignfile);
    }
}


if (!defined($prgsrc)){
    print STDERR "ERROR: Please assign the source programme with --prg. Possible Options are 'exonerate', 'spaln', 'gth' or 'scipio'.\n";
    exit(1);
}

# check program source option
if ($prgsrc ne "exonerate" && $prgsrc ne "spaln" && $prgsrc ne "gth" && $prgsrc ne "scipio"){
    print STDERR "ERROR: Invalid value '$prgsrc' for option --prg. Possible Options are 'exonerate', 'spaln', 'gth' or 'scipio'. Please check.\n";
    exit(1);
}

# set source entry
if ($prgsrc eq "exonerate"){
    $prgsrc = "xnt2h";
}

if ($prgsrc eq "spaln"){
    $prgsrc = "spn2h";
    $intron_threshold = $intron_threshold_spn;
}

if ($prgsrc eq "gth"){
    $prgsrc = "gth2h";
    $intron_threshold = $intron_threshold_gth;
}

if ($prgsrc eq "scipio"){
    $prgsrc = "scipio2h";
}


open (ALN, "<$alignfile") or die("Cannot open file: $alignfile\n");
open (HINTS, ">$hintsfilename") or die("Cannot open file: $hintsfilename");

while(<ALN>) {
    chomp;
    my @f = split(/\t/, $_);
    next unless (scalar(@f) >= 8);
    my $seqname = $f[0];
    my $type = $f[2];
    my $start = $f[3];
    my $end = $f[4];
    my $score = $f[5];
    my $strand = $f[6];
    if ($end < $start){
        my $tmp = $start;
        $start = $end;
        $end = $tmp;
    }
    # get target protein for exonerate
    if($type eq "gene" && $prgsrc eq "xnt2h"){
        /sequence (\S+) ; /;
        $parent = $1;
    }
    # get target protein for gth
    if($type eq "mRNA" && $prgsrc eq "gth2h"){
        my @info = split(/\=/, $f[8]);
        @info = split(/\s/, $info[-1]);
        $parent = $info[0];
    }
    # get target protein for spaln
    if ($prgsrc eq "spn2h" && ($type eq "CDS" || $type eq "cds")){
        my @info = split(/\=/, $f[8]);
        @info = split(/\s/, $info[-1]);
        $parent = $info[0];
    }
    # get target protein for scipio
    if ($type eq "protein_match" && $prgsrc eq "scipio2h"){
        $f[8] =~ m/Query=(\S+) (\d+) (\d+)/;
        $parent = $1;
        $qstart = $2; # start of alignment in query protein
        $qend = $3; # start of alignment in query protein
    }

    if ($type eq "CDS" || $type eq "cds" || $type eq "protein_match"){
        # CDSpart hint
        $start += $CDSpart_cutoff;
        $end -= $CDSpart_cutoff;
        if ($start > $end){
            $start = $end = int(($start+$end)/2);
        }
        print HINTS "$seqname\t$prgsrc\t$CDSpartid\t$start\t$end\t$score\t$strand\t.\tsrc=$source;grp=$parent;pri=$priority\n";
        if ($prgsrc eq "spn2h" || $prgsrc eq "scipio2h"){
            get_intron(\@f);
        }
    }

    if ($type eq "exon" && $prgsrc eq "gth2h"){
        get_intron(\@f);
    }

    # intron hints for exonerate
    if ($type eq "intron"){
        if ($end - $start + 1 >= $minintronlen && $end - $start + 1 <= $maxintronlen){
            print HINTS "$seqname\t$prgsrc\tintron\t$start\t$end\t$score\t$strand\t.\tsrc=$source;grp=$parent;pri=$priority\n";
        }
    }
}
close (ALN) or die("Could not close file $alignfile!\n");
close (HINTS) or die("Could not close file $hintsfilename!\n");


# intron hints for spaln and gth
sub get_intron{
    my $line = shift;
    $intron_score = $prevScore + @{$line}[5] / 2;
    if ($prevParent ne $parent){
        if(@{$line}[6] eq "-" && $prgsrc eq "spn2h"){
            $intron_end = @{$line}[3] - 1;
        }else{
            $intron_start = @{$line}[4] + 1;
        }
    } else {
        if (@{$line}[6] eq "-" && $prgsrc eq "spn2h"){
            $intron_start = @{$line}[4] + 1;
        } else{
            $intron_end = @{$line}[3] - 1;
        }
        if ($intron_end < $intron_start){
            my $tmp = $intron_start;
            $intron_start = $intron_end;
            $intron_end = $tmp;
        }
        # check conditions: length of intron is at least $minintronlen and maximal $maxintronlen and its score
        # is greater than $intron_threshold
        if ($intron_end - $intron_start + 1 >= $minintronlen && $intron_end - $intron_start + 1 <= $maxintronlen &&
            (!defined($intron_threshold) || $intron_score > $intron_threshold)){
            if ($prgsrc ne "scipio2h" || (defined($prevQend) && $prevQend + 1 == $qstart)){
                print HINTS "@{$line}[0]\t$prgsrc\tintron\t$intron_start\t$intron_end\t$intron_score\t@{$line}[6]\t.\tsrc=$source;grp=$parent;pri=$priority\n";
            }
        }
        if (@{$line}[6] eq "-" && $prgsrc eq "spn2h"){
            $intron_end = @{$line}[3] - 1;
        } else {
            $intron_start = @{$line}[4] + 1;
        }
    }
    $prevScore = @{$line}[5] / 2;
    $prevParent = $parent;
    $prevQend = $qend if (defined($qend));
}


