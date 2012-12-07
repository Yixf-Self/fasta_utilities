use namespace::autoclean;

package ReadFastx;
use Mouse;
use Carp;

has fh              => (is => 'ro', isa     => 'GlobRef');
has files           => (is => 'ro', default => sub { \@ARGV }, isa => 'ArrayRef[Str]');
has current_file    => (is => 'ro', isa     => 'Str');
has alignments_only => (is => 'ro', default => 0, isa => 'Bool');

around BUILDARGS => sub {
  my $orig  = shift;
  my $class = shift;
  if (@_ == 1 && !ref $_[0]) {
    return $class->$orig(files => [$_[0]]);
  }
  else {
    return $class->$orig(@_);
  }
};

sub BUILD {
  my $self = shift;
  unless ($self->{fh}) {

    #automatically unzip gzip and bzip files
    @{$self->{files}} = map {
      s/(.*\.gz)\s*$/pigz -dc < $1|/;
      s/(.*\.bz2)\s*$/pbzip2 -dc < $1|/;
      $_
    } @{$self->{files}};

    #if no files read from stdin
    $self->{files} = ['-'] unless @{$self->{files}};
  }
  $self->_set_fh(shift @{$self->{files}});
  my $first_char = getc $self->{fh};
  $self->{reader} =
      $first_char eq ">" ? sub { $self->_read_fasta }
    : $first_char eq "@" ? sub { $self->_read_fastq }
    :                      croak "Not a fasta or fastq file, $first_char is not > or @";
}

sub next_seq {
  my ($self) = shift;
  return &{$self->{reader}};
}

sub _set_fh {
  my ($self, $file) = @_;
  $self->{current_file} = $file;
  open my $fh, $file or croak "$!: Could not open $file\n";
  $self->{fh} = $fh;
}

sub _read_fasta {
  my $self = shift;
  local $/ = ">";
  if (my $record = readline $self->{fh}) {
    chomp $record;
    my $newline = index($record, "\n");
    if ($newline > 1) {
      my $header   = substr($record, 0,            $newline);
      my $sequence = substr($record, $newline + 1);
      $sequence =~ tr/\n//d;
      return ReadFastx::Fasta->new(header => $header, sequence => $sequence);
    }
  }
  elsif (eof $self->{fh}) {
    return unless @{$self->{files}};
    $self->_set_fh(shift @{$self->{files}});
    return ($self->_read_fasta);
  }
  else {
    return undef;
  }
}

sub _read_fastq {
  my $self = shift;
  if (    defined(my $header = readline $self->{fh})
      and defined(my $sequence = readline $self->{fh})
      and defined(my $h2       = readline $self->{fh})
      and defined(my $quality  = readline $self->{fh}))
  {
    $header =~ s/^@//;    #remove @ if it exists
    chomp $header; chomp $sequence; chomp $quality;
    my $seq = ReadFastx::Fastq->new(header => $header, sequence => $sequence, quality => $quality);
    return $seq;
  } 
  elsif (eof $self->{fh}) {
    return unless @{$self->{files}};
    $self->_set_fh(shift @{$self->{files}});
    return $self->_read_fastq;
  }
  else {
    return undef;
  }
}

__PACKAGE__->meta->make_immutable;
1;

package ReadFastx::Fasta;
use Mouse;
use Readonly;

has header   => (is => 'rw', isa => 'Str');
has sequence => (is => 'rw', isa => 'Str');

Readonly my $PRINT_DEFAULT_FH => \*STDOUT;

sub print {
  my ($self, $args) = @_;
  my $fh    = exists $args->{fh}    ? $args->{fh}    : $PRINT_DEFAULT_FH;
  my $width = exists $args->{width} ? $args->{width} : undef;
  my $out;
  if ($width) {
    my $cur = 0;
    while ($cur < length($self->{sequence})) {
      $out .= substr($self->{sequence}, $cur, $width) . "\n";
      $cur += $width;
    }
  }
  else {
    $out = $self->{sequence} . "\n";
  }
  print $fh ">" . $self->{header} . "\n$out";
}

__PACKAGE__->meta->make_immutable;
1;

package ReadFastx::Fastq;
use Mouse;
use Mouse::Util::TypeConstraints;
use Readonly;

Readonly my $ILLUMINA_OFFSET => 64;
Readonly my $SANGER_OFFSET   => 32;

subtype 'ArrayRefOfInts', as 'ArrayRef[Int]';
coerce 'ArrayRefOfInts', from 'Str', via {
  [map { $_ - $SANGER_OFFSET } unpack "c*", $_];
};

has header   => (is => 'rw', isa    => 'Str');
has quality  => (is => 'rw', coerce => 1, isa => 'ArrayRefOfInts');
has sequence => (is => 'rw', isa    => 'Str');

sub print {
  my ($self, $args) = @_;
  my $fh     = exists $args->{fh}       ? $args->{fh}      : $PRINT_DEFAULT_FH;
  my $offset = exists $args->{illumina} ? $ILLUMINA_OFFSET : $SANGER_OFFSET;
  my $quality = $self->quality_str($args);
  print $fh "@" . $self->{header} . "\n" . $self->{sequence} . "\n+" . $self->{header} . "\n" . $quality . "\n";
}

sub illumina_quals {
  my ($self) = @_;
  $_ -= 32 for @{$self->{quality}};
}

sub quality_str {
  my ($self, $args) = @_;
  my $offset = exists $args->{illumina} ? $ILLUMINA_OFFSET : $SANGER_OFFSET;
  return (pack "c*", map { $_ + $offset } @{$self->{quality}});
}

__PACKAGE__->meta->make_immutable;
1;