module ActiveRecord
  module Associations
    class AssociationScope #:nodoc:
      attr_reader :association, :alias_tracker

      delegate :klass, :reflection, :to => :association

      def initialize(association)
        @association   = association
        @alias_tracker = AliasTracker.new klass.connection
      end

      def scope
        scope = klass.unscoped
        scope.extending! Array(reflection.options[:extend])

        owner = association.owner
        scope_chain = reflection.scope_chain
        chain = reflection.chain
        add_constraints(scope, owner, scope_chain, chain)
      end

      def join_type
        Arel::Nodes::InnerJoin
      end

      private

      def construct_tables(chain)
        chain.map do |reflection|
          alias_tracker.aliased_table_for(
            table_name_for(reflection),
            table_alias_for(reflection, reflection != self.reflection)
          )
        end
      end

      def table_alias_for(reflection, join = false)
        name = "#{reflection.plural_name}_#{alias_suffix}"
        name << "_join" if join
        name
      end

      def join(table, constraint)
        table.create_join(table, table.create_on(constraint), join_type)
      end

      def column_for(table_name, column_name)
        columns = alias_tracker.connection.schema_cache.columns_hash(table_name)
        columns[column_name]
      end

      def bind_value(scope, column, value)
        substitute = alias_tracker.connection.substitute_at(
          column, scope.bind_values.length)
        scope.bind_values += [[column, value]]
        substitute
      end

      def bind(scope, table_name, column_name, value)
        column   = column_for table_name, column_name
        bind_value scope, column, value
      end

      def add_constraints(scope, owner, scope_chain, chain)
        tables = construct_tables(chain)

        chain.each_with_index do |reflection, i|
          table, foreign_table = tables.shift, tables.first

          if reflection.source_macro == :belongs_to
            if reflection.options[:polymorphic]
              key = reflection.association_primary_key(self.klass)
            else
              key = reflection.association_primary_key
            end

            foreign_key = reflection.foreign_key
          else
            key         = reflection.foreign_key
            foreign_key = reflection.active_record_primary_key
          end

          if reflection == chain.last
            bind_val = bind scope, table.table_name, key.to_s, owner[foreign_key]
            scope    = scope.where(table[key].eq(bind_val))

            if reflection.type
              value    = owner.class.base_class.name
              bind_val = bind scope, table.table_name, reflection.type.to_s, value
              scope    = scope.where(table[reflection.type].eq(bind_val))
            end
          else
            constraint = table[key].eq(foreign_table[foreign_key])

            if reflection.type
              value    = chain[i + 1].klass.base_class.name
              bind_val = bind scope, table.table_name, reflection.type.to_s, value
              scope    = scope.where(table[reflection.type].eq(bind_val))
            end

            scope = scope.joins(join(foreign_table, constraint))
          end

          is_first_chain = i == 0
          klass = is_first_chain ? self.klass : reflection.klass

          # Exclude the scope of the association itself, because that
          # was already merged in the #scope method.
          scope_chain[i].each do |scope_chain_item|
            item  = eval_scope(klass, scope_chain_item, owner)

            if scope_chain_item == self.reflection.scope
              scope.merge! item.except(:where, :includes, :bind)
            end

            if is_first_chain
              scope.includes! item.includes_values
            end

            scope.where_values += item.where_values
            scope.order_values |= item.order_values
          end
        end

        scope
      end

      def alias_suffix
        reflection.name
      end

      def table_name_for(reflection)
        if reflection == self.reflection
          # If this is a polymorphic belongs_to, we want to get the klass from the
          # association because it depends on the polymorphic_type attribute of
          # the owner
          klass.table_name
        else
          reflection.table_name
        end
      end

      def eval_scope(klass, scope, owner)
        if scope.is_a?(Relation)
          scope
        else
          klass.unscoped.instance_exec(owner, &scope)
        end
      end
    end
  end
end
