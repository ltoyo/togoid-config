#!/usr/bin/env perl

# 20210203 moriya

# 生物種リストをSPARQLで取得して、種毎にIDリストをSPARQLで並列に取得
# SPARQLクエリやprefix、並列スレッド数は update_params.pl に記述
# usage: update.pl > pair.tsv 2> log
#   - 終了時 log ファイルが log.bk になっていれば正常終了
#      - endpoint の出力 limit を超えた場合に未対応（正常応答になるため）
#   - fetch error などで log ファイル残っている場合
#     update.pl >> pair.tsv 2>> log で途中から再開して追記

use JSON;
use URI::Escape;
use LWP::UserAgent;
use threads;
use Thread::Semaphore;
use threads::shared;

require './update_params.pl';

# for resume
our %LOG;
if (-f "./log") {
    open(DATA, "./log");
    while (<DATA>) {
        chomp($_);
        my @a = split(/\t/, $_);
        $LOG{$a[0]} = 1 if ($a[1] =~ /^\d+$/);
    }
    close DATA;
}

our $LOOPC : shared = 0;
our $THREAD_COUNT : shared = 0;
$| = 1;
our $SEMA = new Thread::Semaphore($THREAD_LIMIT);
 
my %th;

# get taxonomy list
my $json = &get("?query=".uri_escape($QUERY_TAX), "get tax:");

# make threads
for my $id (0 .. $#{$json->{results}->{bindings}}) {
    $th{$id} = new threads(\&run, $id, ${$json->{results}->{bindings}}[$id], $SEMA);
}

for (0 .. $#{$json->{results}->{bindings}}) {
    $th{$_}->join();
}

# finish flag
system("mv ./log ./log.bk") if(-f "./log");

# run threads
sub run {
    my ($id, $d, $sema) = @_;
    
    $sema->down();   
    {lock $THREAD_COUNT; $THREAD_COUNT++;}
    {lock $LOOPC; $LOOPC++;}

    my $tax = $d->{org}->{value};
    my $tax_tmp = $tax;
    $tax_tmp =~ s/^.+\/(\d+)$/tax:$1/;
    return 0 if ($LOG{$tax_tmp});  # for resume

    # get ID list
    my $query_main = $QUERY;
    $query_main =~ s/__TAXON__/${tax}/;
    my $json = &get("?query=".uri_escape($query_main), $tax_tmp);

    threads::yield();
    
    {lock $THREAD_COUNT; $THREAD_COUNT--;}
    $sema->up();

    foreach my $el (@{$json->{results}->{bindings}}) {
	$el->{source}->{value} =~ s/^${SOURCE_REGEX}$/$1/;
	$el->{target}->{value} =~ s/^${TARGET_REGEX}$/$1/;
	print $el->{source}->{value}, "\t", $el->{target}->{value}, "\n";
    }
    print STDERR $tax_tmp, "\t", $#{$json->{results}->{bindings}} + 1, "\n";
}

sub get {
    my ($params, $e) = @_;
    
    my $ua = LWP::UserAgent->new;
    
    my $srj = $ua -> get($EP.$params, 'Accept' => 'application/sparql-results+json') -> content;
    eval {
	decode_json($srj);
	1
    } or do {
	$srj = $ua -> get($EP_MIRROR.$params, 'Accept' => 'application/sparql-results+json') -> content if ($EP_MIRROR);
    };

    eval {
	decode_json($srj);
	1
    } or do {
	print STDERR $e, "\tFetch error.\n";
	exit 0;
    };
    
    return decode_json($srj);
}
