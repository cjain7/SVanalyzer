#!/usr/bin/perl -w
# $Id:$

use strict;

use Getopt::Long;
use Pod::Usage;
use GTB::File qw(Open);
use GTB::FASTA;
use NHGRI::MUMmer::AlignSet;
use NHGRI::SVanalyzer::Align2SV;
use GTB::Var::Polymorphism; # for widening of small indels

our %Opt;

# Custom tags added by this script to describe widened variants:
our %TAGSTOADD = ('INFO' => [ 
     '<ID=BREAKSIMLENGTH,Number=1,Type=Integer,Description="Length of alignable similarity at event breakpoints as determined by the aligner">',
     '<ID=REFWIDENED,Number=1,Type=String,Description="Widened boundaries of the event in the reference allele">',
     '<ID=REPTYPE,Number=1,Type=String,Description="Type of SV, with designation of uniqueness of new or deleted sequence:SIMPLEDEL=Deletion of at least some unique sequence, SIMPLEINS=Insertion of at least some unique sequence, CONTRAC=Contraction, or deletion of sequence entirely similar to remaining sequence, DUP=Duplication, or insertion of sequence entirely similar to pre-existing sequence, INV=Inversion, SUBSINS=Insertion of new sequence with alteration of some pre-existing sequence, SUBSDEL=Deletion of sequence with alteration of some remaining sequence">',
                   ] );

=head1 NAME

SVwiden.pl - Read a VCF file and use MUMmer to determine widened coordinates for 
structural variants, adding custom tags to the VCF record.


=head1 SYNOPSIS

  SVwiden.pl --invcf <path to input VCF file> --ref <path to reference multi-FASTA file> --outvcf <path to output VCF file>

For complete documentation, run C<SVwiden.pl -man>

=cut

#------------
# Begin MAIN 
#------------

my $nucmer = `which nucmer`;
my $filterdiff = `which delta-filter`;
if ((!$nucmer) || (!$filterdiff)) {
    die "Running SVwiden requires that the MUMmer tools \'nucmer\' and \'delta-filter\' (http://mummer.sourceforge.net/) be in your Linux path.\n";
}
else {
    chomp $nucmer;
    chomp $filterdiff;
}

process_commandline();

my $ref_fasta = $Opt{ref};
my $ref_db = GTB::FASTA->new($ref_fasta);

my $invcf = $Opt{invcf};
my $invcf_fh = Open($invcf, "r");

my $outvcf = $Opt{outvcf};
my $outvcf_fh = Open($outvcf, "w");

write_header($invcf_fh, $outvcf_fh) if (!$Opt{noheader});

while (<$invcf_fh>) {
    next if (/^#/);

    my $vcf_line = $_;
    my ($chr, $pos, $end, $id, $ref, $alt) = parse_vcf_line($vcf_line);

    process_variant($chr, $pos, $end, $ref, $alt, $ref_db, $outvcf_fh, $vcf_line);
}

close $invcf_fh;
close $outvcf_fh;

#------------
# End MAIN
#------------

sub process_commandline {
    # Set defaults here
    %Opt = ( buffer => 10000, workdir => '.' );
    GetOptions(\%Opt, qw( invcf=s ref=s outvcf=s buffer=i noheader workdir=s manual help+ version)) || pod2usage(0);
    if ($Opt{manual})  { pod2usage(verbose => 2); }
    if ($Opt{help})    { pod2usage(verbose => $Opt{help}-1); }
    if ($Opt{version}) { die "SVwiden.pl, ", q$Revision:$, "\n"; }

    if (!($Opt{invcf})) {
        print STDERR "Must specify a VCF file path of variants to widen with --invcf option!\n"; 
        pod2usage(0);
    }

    if (!($Opt{outvcf})) {
        print STDERR "Must specify a VCF file path to output variants with custom widened tags with --outvcf option!\n"; 
        pod2usage(0);
    }

    if (!($Opt{ref})) {
        print STDERR "Must specify a reference FASTA file path with --ref option!\n"; 
        pod2usage(0);
    }

}

sub parse_vcf_line {
    my $vcf_line = shift;

    if ($vcf_line =~ /^(\S+)\t(\d+)\t(\S+)\t(\S+)\t(\S+)\t(\S+)\t(\S+)\t(\S+)/) {
        my ($chr, $start, $id, $ref, $alt, $info) = ($1, $2, $3, $4, $5, $8);
        $ref = uc($ref);
        $alt = uc($alt);

        my $end; # if we have sequence, end will be determined as last base of REF, otherwise, from END=
        if (($ref =~ /^([ATGCN]+)$/) && ($alt =~ /^([ATGCN]+)$/)) {
            $end = $start + length($ref) - 1;
        }
        else {
            die "Variants must have sequence alleles in REF and ALT fields!\n";
        }

        return ($chr, $start, $end, $id, $ref, $alt);
    }
    else {
        die "Unexpected VCF line:\n$vcf_line";
    }
}

sub write_header {
    my $infh = shift;
    my $outfh = shift;

    my $lasttag;

    while (<$infh>) {
        if (/^##([^=]+)=/) { # transfer all header lines from the input VCF to the output VCF
            my $thistag = $1; 
            my $thisline = $_; 
            if (($lasttag) && ($lasttag ne $thistag)) { # add our tags immediately after similar tags, if they exist
               if ($TAGSTOADD{$lasttag}) {
                   foreach my $tag (@{$TAGSTOADD{$lasttag}}) {
                       print $outfh "##$lasttag=$tag\n";
                   }
                   delete $TAGSTOADD{$lasttag};
               }
            }
            print $outfh $thisline;
            $lasttag = $thistag;
        }
        elsif (/^#CHROM/) {
            my $thisline = $_; 
            # any of our tags left to print?
            foreach my $thistag (keys %TAGSTOADD) {
                foreach my $tag (@{$TAGSTOADD{$thistag}}) {
                    print $outfh "##$thistag=$tag\n";
                }
                delete $TAGSTOADD{$thistag};
            }
            print $outfh $thisline;
            last;
        }
    }
    return 1;
}

sub process_variant {
    my $chrom = shift;
    my $pos = shift;
    my $end = shift;
    my $ref = shift;
    my $alt = shift;
    my $ref_db = shift;
    my $out_fh = shift;
    my $vcf_record = shift;

    my @vcf_fields = split /\t/, $vcf_record;

    # construct the ref and alternate alleles for alignment:

    my $chrom_length = $ref_db->len($chrom);
    my $buffer = $Opt{buffer};
    my $left_end = ($pos > $buffer) ? $pos - $buffer : 1;
    my $right_end = ($end <= $chrom_length - $buffer) ? $end + $buffer : $chrom_length;
    my $ref_allele = $ref_db->seq("$chrom:$left_end-$right_end");

    my $pos_within_ref_allele = $pos - $left_end + 1;
    my $end_within_ref_allele = $end - $left_end + 1;
    # check to be sure we have coords correct:
    my $ref_from_ref = substr($ref_allele, $pos_within_ref_allele - 1, $end - $pos + 1);
    if (uc($ref_from_ref) ne $ref) {
        die "Ref derived from widened ref has different allele from ref!\n";
    }

    # construct alternate haplotype:
    my $alt_allele = $ref_allele;
    substr($alt_allele, $pos_within_ref_allele - 1, $end - $pos + 1, $alt);

    my $workdir = $Opt{'workdir'};
    write_fasta_file("$workdir/ref.fasta", "ref", \$ref_allele);
    write_fasta_file("$workdir/alt.fasta", "alt", \$alt_allele);

    my $delta_file = run_mummer($workdir, "$workdir/ref.fasta", "$workdir/alt.fasta", 'prefix');

    my $rh_refseqs = {'ref' => $ref_allele};
    my $rh_queryseqs = {'alt' => $alt_allele};

    my $delta_obj = NHGRI::MUMmer::AlignSet->new(
                       -delta_file => $delta_file,
                       -storerefentrypairs => 1,
                       -storequeryentrypairs => 1,
                       -extend_exact => 1,
                       -reference_hashref => $rh_refseqs,
                       -query_hashref => $rh_queryseqs,
                       -reference_file => "$workdir/ref.fasta",
                       -query_file => "$workdir/alt.fasta" );

    my $ra_entry_pairs = $delta_obj->{entry_pairs} || [];
    my ($simlength, $reptype, $refwidened);
    if (@{$ra_entry_pairs} == 1) { # as expected
        my $ra_aligns = $ra_entry_pairs->[0]->{aligns};
        my ($left_align, $right_align, $end2end_align);
        foreach my $rh_align (@{$ra_aligns}) {
            my $ref_entry = $rh_align->{ref_entry};
            my $query_entry = $rh_align->{query_entry};
            my $ref_start = $rh_align->{ref_start};
            my $ref_end = $rh_align->{ref_end};
            my $query_start = $rh_align->{query_start};
            my $query_end = $rh_align->{query_end};
            if ($ref_start == 1 && $ref_end == length($ref_allele)) {
                $end2end_align = $rh_align;
            }
            elsif ($ref_start == 1) {
                $left_align = $rh_align;
            }
            elsif ($ref_end == length($ref_allele)) {
                $right_align = $rh_align;
            }
  
            #print STDERR "ALIGN\t$ref_entry\t$ref_start\t$ref_end\t$query_entry\t$query_start\t$query_end\n";
        }
        my @end_aligns = ();
        if ($end2end_align) {
            push @end_aligns, $end2end_align;
        }
        else {
            push @end_aligns, $left_align if ($left_align);
            push @end_aligns, $right_align if ($right_align);
        }

        if (@end_aligns == 2) { # simple SV found
            my $align2sv_obj = NHGRI::SVanalyzer::Align2SV->new(
                                  -delta_obj => $delta_obj,
                                  -left_align => $end_aligns[0], 
                                  -right_align => $end_aligns[1]
                               );
            my $svsize = length($alt) - length($ref);
            if ($svsize < 0) {
                $align2sv_obj->widen_deletion(); 
            }
            else {
                $align2sv_obj->widen_insertion();
            }
            $simlength = $align2sv_obj->{repeat_bases};
            $reptype = $align2sv_obj->{type};
            my $ref1 = $align2sv_obj->{ref1} + $left_end - 1; # adding left_end - 1 to convert back to chrom coords
            my $ref2 = $align2sv_obj->{ref2} + $left_end - 1;
            my $ref1p = ($align2sv_obj->{ref1p}) ? $align2sv_obj->{ref1p} + $left_end - 1 : undef;
            my $ref2p = ($align2sv_obj->{ref2p}) ? $align2sv_obj->{ref2p} + $left_end - 1 : undef;
            $refwidened = ($svsize > 0) ? "$chrom:$ref2-$ref1" : "$chrom:$ref2p-$ref1p";
            print STDERR "BREAKSIMLENGTH $simlength REPTYPE $reptype SIZE $svsize REFWIDENED $refwidened\n";
        }
        elsif (@end_aligns > 2) {
            print STDERR "Complex alignments!\n";
            return {};
        }
        elsif (@end_aligns == 1) { # too small to break alignment
            my $pmo = $pos - 1;
            my $lfs = ($pos > $buffer) ? $pos - $buffer : 1;
            my $left_flank_seq = $ref_db->seq("$chrom:$lfs-$pmo");
            my $rfs = $pos + length($ref);
            my $rfe = ($pos + length($ref) + $buffer - 1 <= $chrom_length) ? $pos + length($ref) + $buffer - 1 : $chrom_length;
            my $right_flank_seq = $ref_db->seq("$chrom:$rfs-$rfe");
            my $orig_svsize = length($alt) - length($ref);

            my $var_to_widen = GTB::Var::Polymorphism->new(
                                  -left_flank_end => $pos - 1,
                                  -right_flank_start => $pos + length($ref),
                                  -left_flank_seq => $left_flank_seq,
                                  -right_flank_seq => $right_flank_seq,
                                  -allele_seqs => [$ref, $alt],
                                  -type => 'indel');
            my $new_svsize = length($var_to_widen->{allele_seqs}->[1]) - length($var_to_widen->{allele_seqs}->[0]);
            if ($orig_svsize != $new_svsize) {
                die "Widening small indel changed size!\n";
            }
            my $new_lfe = $var_to_widen->left_flank_end();
            my $new_rfs = $var_to_widen->right_flank_start();
            $refwidened = "$chrom:$new_lfe-$new_rfs";
            $simlength = ($new_rfs - $new_lfe) - ($rfs - $pmo);
            $reptype = ($orig_svsize < 0) ? (($simlength >= -1*$orig_svsize) ? 'CONTRAC' : 'SIMPLEDEL') :
                                            (($simlength >= -1*$orig_svsize) ? 'DUP' : 'SIMPLEINS');
            print STDERR "BREAKSIMLENGTH $simlength REPTYPE $reptype SIZE $orig_svsize REFWIDENED: $refwidened\n";
        }
    }
    else {
        print STDERR "Unexpected alignments from MUMmer!\n";
        return {};
    }
    my $info_field = $vcf_fields[7];
    my @info_values = split /;/, $info_field;
    push @info_values, "REPTYPE=$reptype" if ($reptype);
    push @info_values, "BREAKSIMLENGTH=$simlength" if (defined($simlength));
    push @info_values, "REFWIDENED=$refwidened" if ($refwidened);
    $vcf_fields[7] = join ';', @info_values;
    $vcf_record = join "\t", @vcf_fields;
    print $out_fh "$vcf_record";
}

sub write_fasta_file {
    my $fasta_file = shift;
    my $seq_id = shift;
    my $r_sequence = shift;

    my $seq_fh = Open("$fasta_file", "w"); 
    print $seq_fh ">$seq_id\n";
    my $r_alt_50 = format_50($r_sequence);
    print $seq_fh ${$r_alt_50};
    if (${$r_alt_50} !~ /\n$/) {
        print $seq_fh "\n";
    }
    close $seq_fh;
}

# format a sequence string for writing to FASTA file
sub format_50 {
    my $r_seq = shift;

    my $bases = 0;
    my $revseq = reverse(${$r_seq});
    my $formattedseq = '';
    while (my $nextbase = chop $revseq) {
        $formattedseq .= $nextbase;
        $bases++;
        if ($bases == 50) {
            $formattedseq .= "\n";
            $bases = 0;
        }
    }
    if ($bases) { # need an extra enter
        $formattedseq .= "\n";
    }

    return \$formattedseq;
}


sub run_mummer {
    my $workingdir = shift;
    my $fasta1 = shift;
    my $fasta2 = shift;
    my $nucmer_name = shift;

    my $mummer_cmd_file = "$workingdir/run_mummer.$nucmer_name.sh";
    my $mummer_fh = Open("$mummer_cmd_file", "w");
    print $mummer_fh "#!/bin/bash\nnucmer -o -p $workingdir/nucmer.$nucmer_name -maxmatch $fasta1 $fasta2\n";
    print $mummer_fh "delta-filter -q $workingdir/nucmer.$nucmer_name.delta > $workingdir/nucmer.$nucmer_name.qdelta\n";
    close $mummer_fh;
    chmod 0755, $mummer_cmd_file;
    
    my $cmd = "$mummer_cmd_file > $workingdir/nucmer.$nucmer_name.out 2> $workingdir/nucmer.$nucmer_name.err";
    system($cmd) == 0
        or print STDERR "Something went wrong running $mummer_cmd_file!\n";

    if ($Opt{'cleanup'}) {
        unlink $fasta1;
        unlink $fasta2;
        unlink "$workingdir/nucmer.$nucmer_name.err";
        unlink "$workingdir/nucmer.$nucmer_name.coords";
        unlink "$workingdir/nucmer.$nucmer_name.out";
        unlink "$workingdir/run_mummer.$nucmer_name.sh";
    }

    return "$workingdir/nucmer.$nucmer_name.qdelta";
}

__END__

=head1 OPTIONS

=over 4

=item B<--ref <path to reference multi-fasta file>>

Specify the path to the multi-fasta file that serves as a reference
for the structural variants in the VCF file.

=item B<--outvcf <path to which to write a new VCF-formatted file>>

Specify the path to which to write a new VCF file containing the structural
variants from the input VCF file, but now with tags specifying widened
coordinates

=item B<--refname <string to include as the reference name in the VCF header>>

Specify a string to be written as the reference name in the ##reference line 
of the VCF header.

=item B<--noheader>

Flag option to suppress printout of the VCF header.

=item B<--help|--manual>

Display documentation.  One C<--help> gives a brief synopsis, C<-h -h> shows
all options, C<--manual> provides complete documentation.

=back

=head1 AUTHOR

 Nancy F. Hansen - nhansen@mail.nih.gov

=head1 LEGAL

This software/database is "United States Government Work" under the terms of
the United States Copyright Act.  It was written as part of the authors'
official duties for the United States Government and thus cannot be
copyrighted.  This software/database is freely available to the public for
use without a copyright notice.  Restrictions cannot be placed on its present
or future use. 

Although all reasonable efforts have been taken to ensure the accuracy and
reliability of the software and data, the National Human Genome Research
Institute (NHGRI) and the U.S. Government does not and cannot warrant the
performance or results that may be obtained by using this software or data.
NHGRI and the U.S.  Government disclaims all warranties as to performance,
merchantability or fitness for any particular purpose. 

In any work or product derived from this material, proper attribution of the
authors as the source of the software or data should be made, using "NHGRI
Genome Technology Branch" as the citation. 

=cut
