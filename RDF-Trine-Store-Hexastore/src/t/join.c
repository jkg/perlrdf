#include <unistd.h>
#include "hexastore.h"
#include "nodemap.h"
#include "node.h"
#include "storage.h"
#include "tap.h"

void _add_data ( hx_hexastore* hx );
hx_variablebindings_iter* _get_triples ( hx_hexastore* hx, int sort );

hx_node* p1;
hx_node* p2;
hx_node* r1;
hx_node* r2;
hx_node* l1;
hx_node* l2;

void test_small_join ( void );

int main ( void ) {
	plan_tests(119);
	p1	= hx_new_node_resource( "p1" );
	p2	= hx_new_node_resource( "p2" );
	r1	= hx_new_node_resource( "r1" );
	r2	= hx_new_node_resource( "r2" );
	l1	= hx_new_node_literal( "l1" );
	l2	= hx_new_node_literal( "l2" );
	
	test_small_join();
	
	return exit_status();
}

void test_small_join ( void ) {
	diag("small join test");
	hx_storage_manager* s	= hx_new_memory_storage_manager();
	hx_hexastore* hx	= hx_new_hexastore( s );
	hx_nodemap* map		= hx_get_nodemap( hx );
	_add_data( hx );
	
	int size;
	char* name;
	char* string;
	hx_node* node;
	hx_node_id nid;
	hx_variablebindings* b;
	hx_variablebindings_iter* iter	= _get_triples( hx, HX_OBJECT );
	ok1( !hx_variablebindings_iter_finished( iter ) );

	hx_variablebindings_iter_current( iter, &b );
	
	size	= hx_variablebindings_size( b );
	ok1( size == 3 );
	name	= hx_variablebindings_name_for_binding( b, 0 );
	ok1( strcmp( name, "subj" ) == 0);
	{
		hx_node_id nid	= hx_variablebindings_node_for_binding( b, 0 );
		hx_node* node	= hx_nodemap_get_node( map, nid );
		ok1( hx_node_cmp( node, r2 ) == 0 );
		ok1( hx_node_cmp( node, r1 ) == 1 );
	}
	
	hx_variablebindings_iter_next( iter );
	{
		ok1( !hx_variablebindings_iter_finished( iter ) );
		hx_variablebindings_iter_current( iter, &b );
		hx_node_id nid	= hx_variablebindings_node_for_binding( b, 0 );
		hx_node* node	= hx_nodemap_get_node( map, nid );
		ok1( hx_node_cmp( node, l2 ) == 0 );
	}
	
	hx_node_string( node, &string );
	fprintf( stderr, "binding: %s => %s\n", name, string );

	hx_variablebindings_string( b, map, &string );
	fprintf( stdout, "%s\n", string );
	
// 	while (!hx_variablebindings_iter_finished( iter )) {
// 		hx_variablebindings* b;
// 		hx_node_id s, p, o;
// 		hx_variablebindings_iter_current( iter, &b );
// 		char* string;
// 		hx_variablebindings_string( b, map, &string );
// 		fprintf( stdout, "%s\n", string );
// 		free( string );
// 		
// 		hx_free_variablebindings( b, 0 );
// 		hx_variablebindings_iter_next( iter );
// 	}
	
	hx_free_variablebindings_iter( iter, 0 );
	hx_free_hexastore( hx );
	hx_free_storage_manager( s );
}

hx_variablebindings_iter* _get_triples ( hx_hexastore* hx, int sort ) {
	hx_node* v1	= hx_new_node_variable( -1 );
	hx_node* v2	= hx_new_node_variable( -2 );
	hx_node* v3	= hx_new_node_variable( -3 );
	
	hx_index_iter* titer	= hx_get_statements( hx, v1, v2, v3, HX_OBJECT );
	hx_variablebindings_iter* iter	= hx_new_iter_variablebindings( titer, "subj", "pred", "obj" );
	return iter;
}

void _add_data ( hx_hexastore* hx ) {
	hx_add_triple( hx, r1, p1, r2 );
	hx_add_triple( hx, r2, p1, r1 );
	hx_add_triple( hx, r2, p2, l2 );
	hx_add_triple( hx, r1, p2, l1 );
}