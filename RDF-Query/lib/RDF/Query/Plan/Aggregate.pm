# RDF::Query::Plan::Aggregate
# -----------------------------------------------------------------------------

=head1 NAME

RDF::Query::Plan::Aggregate - Executable query plan for Aggregates.

=head1 VERSION

This document describes RDF::Query::Plan::Aggregate version 2.901.

=head1 METHODS

=over 4

=cut

package RDF::Query::Plan::Aggregate;

use strict;
use warnings;
use base qw(RDF::Query::Plan);
use Scalar::Util qw(blessed);

use RDF::Query::Error qw(:try);
use RDF::Query::Node qw(literal);

######################################################################

our ($VERSION);
BEGIN {
	$VERSION	= '2.901';
}

######################################################################

=item C<< new ( $pattern, \@group_by, expressions => [ [ $alias, $op, \%options, @attributes ], ... ] ) >>

=cut

sub new {
	my $class	= shift;
	my $plan	= shift;
	my $groupby	= shift;
	my %args	= @_;
	my @ops		= @{ $args{ 'expressions' } || [] };
	my $self	= $class->SUPER::new( $plan, $groupby, \@ops );
	$self->[0]{referenced_variables}	= [
											RDF::Query::_uniq(
												$plan->referenced_variables,
												map {
													($_->isa('RDF::Query::Node::Variable'))
														? $_->name
														: $_->isa('RDF::Query::Node')
															? ()
															: $_->referenced_variables
												} @$groupby)
										];
	return $self;
}

=item C<< execute ( $execution_context ) >>

=cut

sub execute ($) {
	my $self	= shift;
	my $context	= shift;
	if ($self->state == $self->OPEN) {
		throw RDF::Query::Error::ExecutionError -text => "AGGREGATE plan can't be executed while already open";
	}
	my $plan	= $self->[1];
	$plan->execute( $context );
	
	my $l		= Log::Log4perl->get_logger("rdf.query.plan.aggregate");
	if ($plan->state == $self->OPEN) {
		my $query	= $context->query;
		my $bridge	= $context->model;
		
		my %seen;
		my %groups;
		my %group_data;
		my @groupby	= $self->groupby;
		my @ops		= @{ $self->[3] };
		local($RDF::Query::Node::Literal::LAZY_COMPARISONS)	= 1;
		
		while (my $row = $plan->next) {
			$l->debug("aggregate on $row");
			my @group	= map { $query->var_or_expr_value( $row, $_ ) } @groupby;
			my $group	= join('<<<', map { blessed($_) ? $_->as_string : '' } @group);
			push( @{ $group_data{ 'rows' }{ $group } }, $row );
			$group_data{ 'groups' }{ $group }	= \@group;
			foreach my $i (0 .. $#groupby) {
				my $g	= $groupby[$i];
				$group_data{ 'groupby_sample' }{ $group }	= $row;
			}
		}
		
		my @rows;
		GROUP: foreach my $group (keys %{ $group_data{ 'rows' } }) {
			$l->debug( "group: $group" );
			my %options;
			my %aggregates;
			my %passthrough_data;
			my @group	= @{ $group_data{ 'groups' }{ $group } };
			
			my $row_sample	= $group_data{ 'groupby_sample' }{ $group };
			foreach my $g (@groupby) {
				my $name	= ($g->isa('RDF::Query::Expression::Alias') or $g->isa('RDF::Query::Node::Variable'))
							? $g->name
							: $g->sse;
				my $value	= $row_sample->{ $name };
				$passthrough_data{ $name }	= $value;
			}
			
			my @operation_data	= (map { [ @{ $_ }, \%aggregates ] } @ops);
			foreach my $data (@operation_data) {
				my $aggregate_data	= pop(@$data);
				my ($alias, $op, $opts, @cols)	= @$data;
				$options{ $alias }	= $opts;
				my $distinct	= ($op =~ /^(.*)-DISTINCT$/);
				$op				=~ s/-DISTINCT$//;
				my $col	= $cols[0];
				my %agg_group_seen;
				foreach my $row (@{ $group_data{ 'rows' }{ $group } }) {
					my @proj_rows	= map { (blessed($col)) ? $query->var_or_expr_value( $row, $col ) : '*' } @cols;
					if ($distinct) {
						next if ($agg_group_seen{ join('<<<', @proj_rows) }++);
					}
					
					$l->debug( "- row: $row" );
# 					$groups{ $group }	||= { map { $_ => $row->{ $_ } } @groupby };
					if ($op eq 'COUNT') {
						$l->debug("- aggregate op: COUNT");
						my $should_inc	= 0;
						if (not(blessed($col)) and $col eq '*') {
							$should_inc	= 1;
						} else {
							my $value	= $query->var_or_expr_value( $row, $col );
							$should_inc	= (defined $value) ? 1 : 0;
						}
						
						$aggregate_data->{ $alias }{ $group }[0]	= $op;
						$aggregate_data->{ $alias }{ $group }[1]	+= $should_inc;
					} elsif ($op eq 'SUM') {
						$l->debug("- aggregate op: SUM");
						my $value	= $query->var_or_expr_value( $row, $col );
						my $type	= _node_type( $value );
						$aggregate_data->{ $alias }{ $group }[0]	= $op;
						
						my $strict	= 1;
						my $v	= $value->literal_value;
						if (scalar( @{ $aggregate_data->{ $alias }{ $group } } ) > 1) {
							if ($type ne $aggregate_data->{ $alias }{ $group }[2]) {
								if ($context->strict_errors) {
									throw RDF::Query::Error::ComparisonError -text => "Cannot compute SUM aggregate over nodes of multiple types";
								} else {
									$strict	= 0;
								}
							}
							
							$aggregate_data->{ $alias }{ $group }[1]	+= $v;
							$aggregate_data->{ $alias }{ $group }[2]	= $type;
						} else {
							$aggregate_data->{ $alias }{ $group }[1]	= $v;
							$aggregate_data->{ $alias }{ $group }[2]	= $type;
						}
					} elsif ($op eq 'MAX') {
						$l->debug("- aggregate op: MAX");
						my $value	= $query->var_or_expr_value( $row, $col );
						my $type	= _node_type( $value );
						$aggregate_data->{ $alias }{ $group }[0]	= $op;
						
						my $strict	= 1;
						if (scalar( @{ $aggregate_data->{ $alias }{ $group } } ) > 1) {
							if ($type ne $aggregate_data->{ $alias }{ $group }[2]) {
								if ($context->strict_errors) {
									throw RDF::Query::Error::ComparisonError -text => "Cannot compute MAX aggregate over nodes of multiple types";
								} else {
									$strict	= 0;
								}
							}
							
							if ($strict) {
								if ($value > $aggregate_data->{ $alias }{ $group }[1]) {
									$aggregate_data->{ $alias }{ $group }[1]	= $value;
									$aggregate_data->{ $alias }{ $group }[2]	= $type;
								}
							} else {
								if ("$value" gt "$aggregate_data->{ $alias }{ $group }[1]") {
									$aggregate_data->{ $alias }{ $group }[1]	= $value;
									$aggregate_data->{ $alias }{ $group }[2]	= $type;
								}
							}
						} else {
							$aggregate_data->{ $alias }{ $group }[1]	= $value;
							$aggregate_data->{ $alias }{ $group }[2]	= $type;
						}
					} elsif ($op eq 'MIN') {
						$l->debug("- aggregate op: MIN");
						my $value	= $query->var_or_expr_value( $row, $col );
						my $type	= _node_type( $value );
						$aggregate_data->{ $alias }{ $group }[0]	= $op;
						
						my $strict	= 1;
						if (scalar( @{ $aggregate_data->{ $alias }{ $group } } ) > 1) {
							if ($type ne $aggregate_data->{ $alias }{ $group }[2]) {
								if ($context->strict_errors) {
									throw RDF::Query::Error::ComparisonError -text => "Cannot compute MIN aggregate over nodes of multiple types";
								} else {
									$strict	= 0;
								}
							}
							
							if ($strict) {
								if ($value < $aggregate_data->{ $alias }{ $group }[1]) {
									$aggregate_data->{ $alias }{ $group }[1]	= $value;
									$aggregate_data->{ $alias }{ $group }[2]	= $type;
								}
							} else {
								if ("$value" lt "$aggregate_data->{ $alias }{ $group }[1]") {
									$aggregate_data->{ $alias }{ $group }[1]	= $value;
									$aggregate_data->{ $alias }{ $group }[2]	= $type;
								}
							}
						} else {
							$aggregate_data->{ $alias }{ $group }[1]	= $value;
							$aggregate_data->{ $alias }{ $group }[2]	= $type;
						}
					} elsif ($op eq 'SAMPLE') {
						### this is just the MIN code from above, without the strict comparison checking
						$l->debug("- aggregate op: SAMPLE");
						my $value	= $query->var_or_expr_value( $row, $col );
						my $type	= _node_type( $value );
						$aggregate_data->{ $alias }{ $group }[0]	= $op;
						
						if (scalar( @{ $aggregate_data->{ $alias }{ $group } } ) > 1) {
							if ("$value" lt "$aggregate_data->{ $alias }{ $group }[1]") {
								$aggregate_data->{ $alias }{ $group }[1]	= $value;
								$aggregate_data->{ $alias }{ $group }[2]	= $type;
							}
						} else {
							$aggregate_data->{ $alias }{ $group }[1]	= $value;
							$aggregate_data->{ $alias }{ $group }[2]	= $type;
						}
					} elsif ($op eq 'AVG') {
						$l->debug("- aggregate op: AVG");
						my $value	= $query->var_or_expr_value( $row, $col );
						my $type	= _node_type( $value );
						$aggregate_data->{ $alias }{ $group }[0]	= $op;
						
						if (my $cmp = $aggregate_data->{ $alias }{ $group }[3]) {
							if ($type ne $cmp) {
								if ($context->strict_errors) {
									throw RDF::Query::Error::ComparisonError -text => "Cannot compute AVG aggregate over nodes of multiple types";
								}
							}
						}
						
						if (blessed($value) and $value->isa('RDF::Query::Node::Literal') and $value->is_numeric_type) {
							$aggregate_data->{ $alias }{ $group }[1]++;
							$aggregate_data->{ $alias }{ $group }[2]	+= $value->numeric_value;
							$aggregate_data->{ $alias }{ $group }[3]	= $type;
						}
					} elsif ($op eq 'GROUP_CONCAT') {
						$l->debug("- aggregate op: GROUP_CONCAT");
						$aggregate_data->{ $alias }{ $group }[0]	= $op;
						
						my $str		= RDF::Query::Node::Resource->new('sparql:str');

						my @values	= map {
							my $expr	= RDF::Query::Expression::Function->new( $str, $query->var_or_expr_value( $row, $_ ) );
							my $val		= $expr->evaluate( $context->query, $row );
							blessed($val) ? $val->literal_value : '';
						} @cols;
						
	# 					warn "adding '$string' to group_concat aggregate";
						push( @{ $aggregate_data->{ $alias }{ $group }[1] }, @values );
					} else {
						throw RDF::Query::Error -text => "Unknown aggregate operator $op";
					}
				}
			}

			my %row	= %passthrough_data;
			foreach my $agg (keys %aggregates) {
				my $op			= $aggregates{ $agg }{ $group }[0];
				if ($op eq 'AVG') {
					my $value	= ($aggregates{ $agg }{ $group }[2] / $aggregates{ $agg }{ $group }[1]);
					$row{ $agg }	= (blessed($value) and $value->isa('RDF::Trine::Node')) ? $value : RDF::Trine::Node::Literal->new( $value, undef, 'http://www.w3.org/2001/XMLSchema#float' );
				} elsif ($op eq 'GROUP_CONCAT') {
					my $j	= (exists $options{$agg}{seperator}) ? $options{$agg}{seperator} : ' ';
					$row{ $agg }	= RDF::Query::Node::Literal->new( join($j, @{ $aggregates{ $agg }{ $group }[1] }) );
				} elsif ($op =~ /COUNT/) {
					my $value	= $aggregates{ $agg }{ $group }[1];
					$row{ $agg }	= (blessed($value) and $value->isa('RDF::Trine::Node')) ? $value : RDF::Trine::Node::Literal->new( $value, undef, 'http://www.w3.org/2001/XMLSchema#integer' );
				} else {
					my $value	= $aggregates{ $agg }{ $group }[1];
					$row{ $agg }	= (blessed($value) and $value->isa('RDF::Trine::Node')) ? $value : RDF::Trine::Node::Literal->new( $value, undef, $aggregates{ $agg }{ $group }[2] );
				}
			}
			
			my $vars	= RDF::Query::VariableBindings->new( \%row );
			$l->debug("aggregate row: $vars");
			push(@rows, $vars);
		}
		
		$self->[0]{rows}	= \@rows;
		$self->state( $self->OPEN );
	} else {
		warn "could not execute plan in distinct";
	}
	$self;
}

=item C<< next >>

=cut

sub next {
	my $self	= shift;
	unless ($self->state == $self->OPEN) {
		throw RDF::Query::Error::ExecutionError -text => "next() cannot be called on an un-open AGGREGATE";
	}
	return shift(@{ $self->[0]{rows} });
}

=item C<< close >>

=cut

sub close {
	my $self	= shift;
	unless ($self->state == $self->OPEN) {
		throw RDF::Query::Error::ExecutionError -text => "close() cannot be called on an un-open AGGREGATE";
	}
	delete $self->[0]{rows};
	$self->[1]->close();
	$self->SUPER::close();
}

=item C<< pattern >>

Returns the query plan that will be used to produce the aggregated data.

=cut

sub pattern {
	my $self	= shift;
	return $self->[1];
}

=item C<< groupby >>

Returns the grouping arguments that will be used to produce the aggregated data.

=cut

sub groupby {
	my $self	= shift;
	return @{ $self->[2] || [] };
}

=item C<< plan_node_name >>

Returns the string name of this plan node, suitable for use in serialization.

=cut

sub plan_node_name {
	return 'aggregate';
}

=item C<< sse ( $context, $indent ) >>

=cut

sub sse {
	my $self	= shift;
	my $context	= shift;
	my $indent	= shift;
	my $more	= '    ';
	my $psse	= $self->pattern->sse( $context, "${indent}${more}" );
	my @group	= map { $_->sse($context, "${indent}${more}") } $self->groupby;
	my $gsse	= join(' ', @group);
	my @ops;
	foreach my $p (@{ $self->[3] }) {
		my ($alias, $op, $options, @cols)	= @$p;
		my $cols	= '(' . join(' ', map { $_->sse($context, "${indent}${more}") } @cols) . ')';
		my @opts_keys	= keys %$options;
		if (@opts_keys) {
			my $opt_string	= '(' . join(' ', map { $_, qq["$options->{$_}"] } @opts_keys) . ')';
			push(@ops, qq[("$alias" "$op" $cols $opt_string)]);
		} else {
			push(@ops, qq[("$alias" "$op" $cols)]);
		}
	}
	my $osse	= join(' ', @ops);
	return sprintf(
		"(aggregate\n${indent}${more}%s\n${indent}${more}(%s)\n${indent}${more}(%s))",
		$psse,
		$gsse,
		$osse,
	);
}

# =item C<< plan_prototype >>
# 
# Returns a list of scalar identifiers for the type of the content (children)
# nodes of this plan node. See L<RDF::Query::Plan> for a list of the allowable
# identifiers.
# 
# =cut
# 
# sub plan_prototype {
# 	my $self	= shift;
# 	return qw(P \E *\ssW);
# }
# 
# =item C<< plan_node_data >>
# 
# Returns the data for this plan node that corresponds to the values described by
# the signature returned by C<< plan_prototype >>.
# 
# =cut
# 
# sub plan_node_data {
# 	my $self	= shift;
# 	my @group	= $self->groupby;
# 	my @ops		= @{ $self->[3] };
# 	return ($self->pattern, \@group, map { [@$_] } @ops);
# }

=item C<< distinct >>

Returns true if the pattern is guaranteed to return distinct results.

=cut

sub distinct {
	my $self	= shift;
	return $self->pattern->distinct;
}

=item C<< ordered >>

Returns true if the pattern is guaranteed to return ordered results.

=cut

sub ordered {
	my $self	= shift;
	my $sort	= [ $self->groupby ];
	return []; # XXX aggregates are actually sorted, so figure out what should go here...
}

sub _node_type {
	my $node	= shift;
	if (blessed($node)) {
		if ($node->isa('RDF::Query::Node::Literal')) {
			if (my $type = $node->literal_datatype) {
				return $type;
			} else {
				return 'literal';
			}
		} elsif ($node->isa('RDF::Query::Node::Resource')) {
			return 'resource';
		} elsif ($node->isa('RDF::Query::Node::Blank')) {
			return 'blank';
		} else {
			return '';
		}
	} else {
		return '';
	}
}

1;

__END__

=back

=head1 AUTHOR

 Gregory Todd Williams <gwilliams@cpan.org>

=cut
