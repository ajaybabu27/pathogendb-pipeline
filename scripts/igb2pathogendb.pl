#!/usr/bin/perl

# 29.01.2015 13:15:27 EST
# Harm van Bakel <hvbakel@gmail.com>

# MODULES
use strict;
use warnings;
use DBI;
use Getopt::Long;

# GLOBALS
my $sDbConf = "$ENV{HOME}/.my.cnf";  # MySQL conf file with db password

# GET PARAMETERS
my $sHelp      = 0;
my $sIgbDir    = "";
my $sCuratedBy = "";
GetOptions("help!"        => \$sHelp,
           "input:s"      => \$sIgbDir,
           "curatedby:s"  => \$sCuratedBy);

# PRINT HELP
$sHelp = 1 unless($sIgbDir);
if ($sHelp) {
   my $sScriptName = ($0 =~ /^.*\/(.+$)/) ? $1 : $0;
   die <<HELP

   Usage: $sScriptName [-c <curator>] 
   
   Arguments:
    -i <string>
      IGB genome directory 
    -c <string>
      For genomes that have been curated, include the name
      of the curator. Optional argument.
    -help
      This help message
   
HELP
}


##########
## MAIN ##
##########

# Check if the IGB dir exists and has a genome file
$sIgbDir =~ s/\/$//;
die "Error: '$sIgbDir' does not exist or is not a directory\n" unless (-d $sIgbDir);
die "Error: '$sIgbDir' does not contain a 'genome.txt' file\n" unless (-e "$sIgbDir/genome.txt");

# Get the run ID and valid pathogenID from the IGB folder
my ($sFolderName, $sRunID, $sAddID, $sIsolateID) = parse_ids_from_foldername($sIgbDir);

# Check the identifiers
my $flIDerror = 0;
$flIDerror = 1 unless ($sRunID =~ /^[A-Z]?\d+$/);
$flIDerror = 1 unless ($sAddID =~ /^\d+[A-Z]+$/);
$flIDerror = 1 unless ($sIsolateID =~ /^[A-Z]{2}\d{5}$/);
if ($flIDerror){
   die <<FOLDER
   Error: IGB folder does not conform to standard naming guidelines.
   
   Please format the folder name according to the following example:
      <species>_ER00023_1A_020225
   
   where:
    - ER00023 is the isolate ID (two capitals followed by 5 numbers)
    - 1A      is the stock/extract ID (one or more numbers, followed by one or capitals)
    - 020225  is the SMRT portal run ID for this particular assembly

FOLDER
}
my $sExtractID = join('.', $sIsolateID, $sAddID);

# Check the curator name
if ($sCuratedBy){
   die "Error: curator name can only contain letters, numbers and underscores\n" unless $sCuratedBy =~ /^[\w\s]+$/
}

# Get the genome stats
my ($nTotalSize, $nMaxContigLength, $sMaxContigID, $nN50length, $nContigCount) = get_stats_from_genomefile("$sIgbDir/genome.txt");

# Get the mlst data if available
my ($sMLST, $sMLSTclade) = (-e "$sIgbDir/mlst.txt") ? get_mlst_data("$sIgbDir/mlst.txt") : ('', '');

#--------------------#
# UPLOAD STARTS HERE #
#--------------------#

# Check if database connection file exists
die "Error: can't find database connection details file '$sDbConf'\n" unless (-e $sDbConf);

# Open database connection
my $dbh = DBI->connect("DBI:mysql:vanbah01_pathogens"
                     . ";mysql_read_default_file=$ENV{HOME}/.my.cnf"
                     . ';mysql_read_default_group=vanbah01_pathogens',
                       undef, undef) or die "Error: could not establish database connection ($DBI::errstr)";

# Check database to make sure the extract ID exists
my $sSQL   = "SELECT E.extract_ID FROM tExtracts E WHERE E.extract_ID=\"$sExtractID\"";
my $oQuery = $dbh->prepare($sSQL);
my $nCount = $oQuery->execute();
$oQuery->finish();
if ($nCount eq '0E0'){
   $dbh->disconnect();
   die "Warning: extract ID '$sExtractID' was not found in the database, no data was uploaded\n";
}

# Save data into tAssemblies
$sSQL   = join(" ",
               "INSERT INTO tAssemblies (extract_ID, assembly_ID, assembly_data_link, contig_count, contig_N50, contig_maxlength, contig_maxID, contig_sumlength, mlst_subtype, mlst_clade, curated_by)",
               "VALUES('$sExtractID', '$sRunID', '$sFolderName', '$nContigCount', '$nN50length', '$nMaxContigLength', '$sMaxContigID', '$nTotalSize', '$sMLST', '$sMLSTclade', '$sCuratedBy')",
               "ON DUPLICATE KEY UPDATE assembly_data_link='$sFolderName', contig_count='$nContigCount', contig_N50='$nN50length', contig_maxlength='$nMaxContigLength', contig_maxID='$sMaxContigID', contig_sumlength='$nTotalSize', mlst_subtype='$sMLST', mlst_clade='$sMLSTclade', curated_by='$sCuratedBy'");
$nCount = $dbh->do($sSQL);
if ($nCount){
   print "Loaded assembly '$sRunID' for extract '$sExtractID' into pathogenDB\n";
}
else{
   warn "Error: Could not load assembly '$sRunID' for extract '$sExtractID' into pathogenDB\n";
}

# Save data into tSequencing_runs
$sSQL   = join(" ",
               "INSERT INTO tSequencing_runs (extract_ID, sequence_run_ID, sequencing_platform, paired_end, run_data_link)",
               "VALUES('$sExtractID', '$sRunID', 'Pacbio', 'No', 'http://smrtportal.hpc.mssm.edu:8080/smrtportal/#/View-Data/Details-of-Job/$sRunID')",
               "ON DUPLICATE KEY UPDATE sequencing_platform='Pacbio', paired_end='No', run_data_link='http://smrtportal.hpc.mssm.edu:8080/smrtportal/#/View-Data/Details-of-Job/$sRunID'");
$nCount = $dbh->do($sSQL);
if ($nCount){
   print "Loaded sequencing run '$sRunID' for extract '$sExtractID' into pathogenDB\n";
}
else{
   warn "Error: Could not load sequencing run '$sRunID' for extract '$sExtractID' into pathogenDB\n";
}

# Update the sequencing core sample tracking system
$sSQL   = "SELECT C.extract_ID FROM tPacbioCoreSubmissions C WHERE C.extract_ID=\"$sExtractID\" AND request_type=\"WGS\"";
$oQuery = $dbh->prepare($sSQL);
$nCount = $oQuery->execute();
$oQuery->finish();
unless ($nCount eq '0E0'){
   $sSQL   = "UPDATE tPacbioCoreSubmissions C SET sequencing_status=\"3 - Prep complete\" WHERE C.extract_ID=\"$sExtractID\" AND C.request_type=\"WGS\"";
   $nCount = $dbh->do($sSQL);
   if ($nCount){
      print "Updated the WGS status for '$sExtractID' in the pathogenDB sequencing core sample tracking system\n";
   }
   else{
      warn "Error: Could not update sequencing core tracking system for '$sExtractID'\n";
   }
}


# Disconnect from database
$dbh->disconnect();


#################
## SUBROUTINES ##
#################

# parse_ids_from_foldername
#
# Get the isolate, extract and SMRT portal ID from the IGB folder name
sub parse_ids_from_foldername {
   my ($sIgbDir) = @_;
   my ($sRunID, $sAddID, $sIsolateID) = ('', '', '');
   
   $sIgbDir =~ s/\/$//;
   my (@asFolderPath) = split /\//, $sIgbDir;
   my $sFolderName = pop @asFolderPath;
   
   my (@asFolderName) = split /\_/, $sIgbDir;
   if (@asFolderName >= 3){
      $sRunID     = pop @asFolderName;
      $sAddID     = pop @asFolderName;
      $sIsolateID = pop @asFolderName;
   }
   return($sFolderName, $sRunID, $sAddID, $sIsolateID);
}


# get_stats_from_genomefile
#
# Get total contig size, max contig size and assembly N50 from the genome file
sub get_stats_from_genomefile {
   my ($sGenome) = @_;

   # Get max length and sum
   my @anContigLengths;
   my ($nSumContigLength, $nMaxContigLength, $sMaxContigID, $nContigCount) = (0, 0, "", 0);
   open GENOME, $sGenome or die "Error: can't open '$sGenome': $!\n";
   while (<GENOME>){
      next if (/^\s*$/);
      next if (/^ *#/);
      s/[\n\r]+$//;
      my ($sContigID, $nContigLength) = split /\t/;
      die "Error: '$sGenome' contains a non-numeric contig length value on line $.\n" unless ($nContigLength =~ /^\d+$/);
      unless ($sContigID =~ /_m_\d+$/){
         if ($nContigLength > $nMaxContigLength){
            $nMaxContigLength = $nContigLength;
            $sMaxContigID     = $sContigID;
         }
         push @anContigLengths, $nContigLength;
         $nSumContigLength += $nContigLength;
         $nContigCount++;
      }
   }
   close GENOME;
   
   # Get N50
   my ($nN50, $nCumSum) = (0, 0);
   foreach my $nLength (sort {$b <=> $a} @anContigLengths){
      $nCumSum += $nLength;
      if ( ($nCumSum/$nSumContigLength) > 0.5){
         $nN50 = $nLength;
         last;
      }
   }
   
   return($nSumContigLength, $nMaxContigLength, $sMaxContigID, $nN50, $nContigCount);
}

# get_mlst_data
#
# Get MLST data from pubmlst.org
sub get_mlst_data {
   my ($sFile) = @_;
   my ($sMLST, $sClade) = ('', '');
   
   open MLST, $sFile or die "Error: can't open '$sFile': \n";
   while (<MLST>){
      next if (/^\s*$/);
      next if (/^ *#/);
      if (/^no_match_found/){
         $sMLST  = "No_match";
         $sClade = "Not_defined";
         last;
      }
      s/[\n\r]+$//;
      my (@asLine) = split /\t+/;
      $sMLST  = $asLine[1] if ($asLine[0] eq "ST");
      $sClade = $asLine[1] if ($asLine[0] eq "clonalcomplex");
      $sClade = $asLine[1] if ($asLine[0] eq "mlstclade");
   }
   close MLST;
   $sClade =~ s/Notdefined/Not_defined/;
   return($sMLST, $sClade);
}
