use Test::More tests => 183;
use Test::Exception;

use strict;
use warnings;

use DBI;
use RDF::Trine::Model;
use RDF::Trine::Node;
use RDF::Trine::Pattern;
use RDF::Trine::Namespace;
use RDF::Trine::Store::DBI;
use RDF::Trine::Statement;
use File::Temp qw(tempfile);

my $rdf		= RDF::Trine::Namespace->new('http://www.w3.org/1999/02/22-rdf-syntax-ns#');
my $foaf	= RDF::Trine::Namespace->new('http://xmlns.com/foaf/0.1/');
my $kasei	= RDF::Trine::Namespace->new('http://kasei.us/');
my $b		= RDF::Trine::Node::Blank->new();
my $p		= RDF::Trine::Node::Resource->new('http://kasei.us/about/foaf.xrdf#greg');
my $st0		= RDF::Trine::Statement->new( $p, $rdf->type, $foaf->Person );
my $st1		= RDF::Trine::Statement->new( $p, $foaf->name, RDF::Trine::Node::Literal->new('Gregory Todd Williams') );
my $st2		= RDF::Trine::Statement->new( $b, $rdf->type, $foaf->Person );
my $st3		= RDF::Trine::Statement->new( $b, $foaf->name, RDF::Trine::Node::Literal->new('Eve') );

my ($stores, $remove)	= stores();
foreach my $store (@$stores) {
	isa_ok( $store, 'RDF::Trine::Store::DBI' );
	my $model	= RDF::Trine::Model->new( $store );
	isa_ok( $model, 'RDF::Trine::Model' );
	$model->add_statement( $_ ) for ($st0, $st1, $st2, $st3);
	
	{
		is( $model->count_statements(), 4, 'model size' );
		$model->add_statement( $_ ) for ($st0);
		is( $model->count_statements(), 4, 'model size after duplicate statements' );
		is( $model->count_statements( undef, $foaf->name, undef ), 2, 'count of foaf:name statements' );
	}
	
	{
		my $stream	= $model->get_statements( $p, $foaf->name, RDF::Trine::Node::Variable->new('name') );
		my $st		= $stream->next;
		is_deeply( $st, $st1, 'foaf:name statement' );
		is( $stream->next, undef, 'end-of-stream' );
	}
	
	{
		my $stream	= $model->get_statements( $b, $foaf->name, RDF::Trine::Node::Variable->new('name') );
		my $st		= $stream->next;
		is_deeply( $st, $st3, 'foaf:name statement (with bnode in triple)' );
		is( $stream->next, undef, 'end-of-stream' );
	}
	
	{
		my $stream	= $model->get_statements( RDF::Trine::Node::Variable->new('p'), $foaf->name, RDF::Trine::Node::Literal->new('Gregory Todd Williams') );
		my $st		= $stream->next;
		is_deeply( $st, $st1, 'foaf:name statement (with literal in triple)' );
		is( $stream->next, undef, 'end-of-stream' );
	}

	{
		my $stream	= $model->get_statements( RDF::Trine::Node::Variable->new('p'), $foaf->name, RDF::Trine::Node::Variable->new('name') );
		my $count	= 0;
		while (my $st = $stream->next) {
			my $subj	= $st->subject;
			isa_ok( $subj, 'RDF::Trine::Node' );
			$count++;
		}
		is( $count, 2, 'expected result count (2 people)' );
	}
	
	{
		my $p1		= RDF::Trine::Statement->new( RDF::Trine::Node::Variable->new('p'), $rdf->type, $foaf->Person );
		my $p2		= RDF::Trine::Statement->new( RDF::Trine::Node::Variable->new('p'), $foaf->name, RDF::Trine::Node::Variable->new('name') );
		my $pattern	= RDF::Trine::Pattern->new( $p1, $p2 );
		
		{
			my $stream	= $model->get_pattern( $pattern );
			my $count	= 0;
			while (my $b = $stream->next) {
				isa_ok( $b, 'HASH' );
				isa_ok( $b->{p}, 'RDF::Trine::Node', 'node person' );
				isa_ok( $b->{name}, 'RDF::Trine::Node::Literal', 'literal name' );
				like( $b->{name}->literal_value, qr/Eve|Gregory/, 'name pattern' );
				$count++;
			}
			is( $count, 2, 'expected result count (2 people)' );
		}
	
		{
			my $stream	= $model->get_pattern( $pattern, undef, orderby => [ 'name', 'ASC' ] );
			is_deeply( [ $stream->sorted_by ], ['name', 'ASC'], 'results sort order' );
			my $count	= 0;
			my @expect	= ('Eve', 'Gregory Todd Williams');
			while (my $b = $stream->next) {
				isa_ok( $b, 'HASH' );
				isa_ok( $b->{p}, 'RDF::Trine::Node', 'node person' );
				my $name	= shift(@expect);
				is( $b->{name}->literal_value, $name, 'name pattern' );
				$count++;
			}
			is( $count, 2, 'expected result count (2 people)' );
		}

		{
			my $stream	= $model->get_pattern( $pattern, undef, orderby => [ 'date', 'ASC' ] );
			is_deeply( [ $stream->sorted_by ], [], 'results sort order for unknown binding' );
		}
		
		{
			throws_ok {
				my $stream	= $model->get_pattern( $pattern, undef, orderby => [ 'name' ] );
			} 'Error', 'bad ordering request throws exception';
		}
	}
	
	{
		my $stream	= $model->get_pattern( $st0 );
		my $empty	= $stream->next;
		is_deeply( $empty, {}, 'empty binding on no-variable pattern' );
		is( $stream->next, undef, 'end-of-stream' );
	}
	
	{
		my $stream	= $model->as_stream();
		isa_ok( $stream, 'RDF::Trine::Iterator::Graph' );
		my $count	= 0;
		while (my $st = $stream->next) {
			my $p	= $st->predicate;
			like( $p->uri_value, qr<(#type|/name)$>, 'as_stream statement' );
			$count++;
		}
		is( $count, 4, 'expected model statement count (4)' );
	}
	
	{
		my $st5		= RDF::Trine::Statement->new( $p, $foaf->name, RDF::Trine::Node::Literal->new('グレゴリ　ウィリアムス', 'jp') );
		$model->add_statement( $st5 );
		
		my $pattern	= RDF::Trine::Statement->new( $p, $foaf->name, RDF::Trine::Node::Variable->new('name') );
		my $stream	= $model->get_pattern( $pattern );
		my $count	= 0;
		while (my $b = $stream->next) {
			isa_ok( $b, 'HASH' );
			isa_ok( $b->{name}, 'RDF::Trine::Node::Literal', 'literal name' );
			like( $b->{name}->literal_value, qr/Gregory|グレゴリ/, 'name pattern　with language-tagged result' );
			$count++;
		}
		is( $count, 2, 'expected result count (2 names)' );
		is( $model->count_statements(), 5, 'model size' );
		$model->remove_statement( $st5 );
		is( $model->count_statements(), 4, 'model size after remove_statement' );
	}
	
	{
		my $st6		= RDF::Trine::Statement->new( $p, $foaf->name, RDF::Trine::Node::Literal->new('Gregory Todd Williams', undef, 'http://www.w3.org/2000/01/rdf-schema#Literal') );
		$model->add_statement( $st6 );
		
		my $pattern	= RDF::Trine::Statement->new( $p, $foaf->name, RDF::Trine::Node::Variable->new('name') );
		my $stream	= $model->get_pattern( $pattern );
		my $count	= 0;
		my $dt		= 0;
		while (my $b = $stream->next) {
			my $name	= $b->{name};
			isa_ok( $b, 'HASH' );
			isa_ok( $name, 'RDF::Trine::Node::Literal', 'literal name' );
			is( $name->literal_value, 'Gregory Todd Williams', 'name pattern　with datatyped result' );
			if (my $type = $name->literal_datatype) {
				is( $type, 'http://www.w3.org/2000/01/rdf-schema#Literal', 'datatyped literal' );
				$dt++;
			}
			$count++;
		}
		is( $count, 2, 'expected result count (2 names)' );
		is( $dt, 1, 'expected result count (1 datatyped literal)' );
	}
	
	{
		$model->remove_statements( $p );
		is( $model->count_statements(), 2, 'model size after remove_statements' );
	}
	
	{
		throws_ok {
			my $pattern	= RDF::Trine::Pattern->new();
			my $stream	= $model->get_pattern( $pattern );
		} 'RDF::Trine::Error::CompilationError', 'empty GGP throws exception';
	}
}

foreach my $file (@$remove) {
	unlink( $file );
}

sub stores {
	my @stores;
	my @removeme;
	{
		my $store	= RDF::Trine::Store::DBI->new();
		$store->init();
		push(@stores, $store);
	}
	
	{
		my ($fh, $filename) = tempfile();
		undef $fh;
		my $dbh		= DBI->connect( "dbi:SQLite:dbname=${filename}", '', '' );
		my $store	= RDF::Trine::Store::DBI->new( 'model', $dbh );
		$store->init();
		push(@stores, $store);
		push(@removeme, $filename);
	}
	
	{
		my ($fh, $filename) = tempfile();
		undef $fh;
		my $dsn		= "dbi:SQLite:dbname=${filename}";
		my $store	= RDF::Trine::Store::DBI->new( 'model', $dsn, '', '' );
		$store->init();
		push(@stores, $store);
		push(@removeme, $filename);
	}
	return (\@stores, \@removeme);
}

sub debug {
	my $store	= shift;
	my $dbh		= $store->dbh;
	my $sth		= $dbh->prepare( "SELECT * FROM Statements15799945864759145248" );
	$sth->execute();
	while (my $row = $sth->fetchrow_hashref) {
		warn Dumper($row);
	}
}