require 'class_associations'
require 'dry_transaction_rollbacks' unless defined?(ActiveRecord::Rollback) # Supported on edge
require 'eval_call'

require 'has_states/active_state'
require 'has_states/state_transition'
require 'has_states/active_event'

module PluginAWeek #:nodoc:
  module Has #:nodoc:
    # A state machine is a model of behavior composed of states, transitions,
    # and events.  This helper adds support for defining this type of
    # functionality within your ActiveRecord models.
    # 
    # Switch example:
    # 
    #   class Switch < ActiveRecord::Base
    #     has_states :initial => :off
    #     
    #     state :off, :on
    #     
    #     event :turn_on do
    #       transition_to :on, :from => :off
    #     end
    #     
    #     event :turn_off do
    #       transition_to :off, :from => :on
    #     end
    #   end
    module States
      class StatefulModel < ActiveRecord::Base #:nodoc:
      end
      
      # An unknown state was specified
      class StateNotFound < StandardError
      end
      
      # An inactive state was specified
      class StateNotActive < StandardError
      end
      
      # A state has already been activated
      class StateAlreadyActive < StandardError
      end
      
      # An unknown event was specified
      class EventNotFound < StandardError
      end
      
      # An inactive state was specified
      class EventNotActive < StandardError
      end
      
      # No initial state was specified for the machine
      class NoInitialState < StandardError
      end
      
      class << self
        # Migrates up the model's table by adding support for states.  The
        # +model+ parameter can either be the class or a symbol/string version
        # of the model's table name.  For example, the following are all
        # equivalent:
        # 
        #   PluginAWeek::Has::States.migrate_up(Vehicle)
        #   PluginAWeek::Has::States.migrate_up(:vehicles)
        #   PluginAWeek::Has::States.migrate_up('vehicles')
        # 
        # An additional options hash can be passed in that will be used when
        # invoking +add_column+.
        # 
        # By default, this will assume null is not allowed for state_id and that
        # the default value is 0.
        def migrate_up(model, options = {})
          if !model.is_a?(Class)
            StatefulModel.set_table_name(model.to_s)
            model = StatefulModel
          end
          
          if !model.column_names.include?(:state_id)
            options.reverse_merge!(:null => false, :unsigned => true)
            options[:default] ||= 0 if !options[:null]
            ActiveRecord::Base.connection.add_column(model.table_name, :state_id, :integer, options)
          end
        end
        
        # Migrates down the model's table by removing support for states.  The
        # +model+ parameter can either be the class or a symbol/string version
        # of the model's table name.  For example, the following are all
        # equivalent:
        # 
        #   PluginAWeek::Has::States.migrate_down(Vehicle)
        #   PluginAWeek::Has::States.migrate_down(:vehicles)
        #   PluginAWeek::Has::States.migrate_down('vehicles')
        def migrate_down(model)
          if !model.is_a?(Class)
            StatefulModel.set_table_name(model.to_s)
            model = StatefulModel
          end
          
          ActiveRecord::Base.connection.remove_column(model.table_name, :state_id)
        end
        
        def included(base) #:nodoc:
          base.extend(MacroMethods)
        end
      end
      
      module MacroMethods
        # Adds support to the current class for tracking the current state of
        # any record.
        # 
        # Configuration options:
        # * <tt>initial</tt> - The initial state to place each record in.  This can either be a string/symbol or a Proc for dynamic initial states.
        # * <tt>record_changes</tt> - Whether or not to record changes to the model's state
        # 
        # == Class associations
        # 
        # When a model has states, it and its subclasses will have the
        # following associations created:
        # * +states+ - A collection of valid states for the class (and its superclasses)
        # * +events+ - A collection of valid events for the class (and its superclasses)
        # * +state_changes+ - If +record_changes+ is enabled, this will be a collection of state changes that have occurred on all records in the class
        # 
        # == Instance associations
        # 
        # In addition to class associations, the following instance assocations
        # will be created when a model has states:
        # * +state+ - The current state of the record
        # * +state_changes+ - If +record_changes+ is enabled, this be a collection of all state changes that have occurred in this record
        def has_states(options)
          options.assert_valid_keys(
            :initial,
            :record_changes
          )
          raise NoInitialState unless options[:initial]
          
          options.reverse_merge!(:record_changes => true)
          
          # Save options for referencing later
          write_inheritable_attribute :active_states, {}
          write_inheritable_attribute :active_events, {}
          write_inheritable_attribute :initial_state, options[:initial]
          write_inheritable_attribute :record_state_changes, options[:record_changes]
          
          class_inheritable_reader  :active_states
          class_inheritable_reader  :active_events
          class_inheritable_writer  :initial_state
          class_inheritable_reader  :record_state_changes
          
          before_create :set_initial_state_id
          after_create  :run_initial_state_actions
          
          belongs_to  :state
          has_many    :state_changes,
                        :as => :stateful,
                        :dependent => :destroy if record_state_changes
          
          class << self
            has_many  :states,
                        :include_superclasses => true
            has_many  :events,
                        :include_superclasses => true
            has_many  :state_changes,
                        :as => :stateful if record_state_changes
            
            # Deprecate errors from Rails 1.2.* force us to remove the method
            remove_method(:find_in_states) if method_defined?(:find_in_states)
          end
          
          klass = self
          State.class_eval do
            has_many klass.to_s.tableize.to_sym
          end
          
          extend PluginAWeek::Has::States::ClassMethods
          include PluginAWeek::Has::States::InstanceMethods
        end
      end
      
      module ClassMethods
        def self.extended(base) #:nodoc:
          class << base
            alias_method_chain :inherited, :states
          end
        end
        
        def inherited_with_states(subclass) #:nodoc:
          inherited_without_states(subclass)
          
          # Update the active events to point to the new subclass
          subclass.active_events.each do |name, event|
            event = event.dup
            event.owner_class = subclass
            subclass.active_events[name] = event
          end
          
          # Update the active states to point to the new subclass
          subclass.active_states.each do |name, state|
            state = state.dup
            state.owner_class = subclass
            subclass.active_states[name] = state
          end
        end
        
        # Checks whether the given name is an active state in the system.  +name+
        # can either be a Symbol or String.
        def active_state?(name)
          active_states.keys.include?(name.to_sym)
        end
        
        # Finds all records that are in a given set of states.
        # 
        # Options:
        # * +number+ - :first or :all
        # * +state_names+ - A state name or list of state names to find
        # * +args+ - The rest of the args are passed down to ActiveRecord::Base's +find+
        # 
        # == Examples
        # 
        #   Car.find_in_state(:first, :parked)
        #   Car.find_in_states(:all, :parked, :idle)
        #   Car.find_in_state(:all, :idle, :order => 'id DESC')
        def find_in_states(number, *args)
          with_state_scope(args) do |options|
            find(number, options)
          end
        end
        alias_method :find_in_state, :find_in_states
        
        # Counts all records in a given set of states.
        # 
        # Options:
        # * +state_names+ - A state name or list of state names to find
        # * +args+ - The rest of the args are passed down to ActiveRecord::Base's +find+
        # 
        # == Examples
        # 
        #   Car.count_in_state(:parked)
        #   Car.count_in_states(:parked, :idle)
        #   Car.count_in_state(:idle, :conditions => ['highway_id = ?', 1])
        def count_in_states(*args)
          with_state_scope(args) do |options|
            count(options)
          end
        end
        alias_method :count_in_state, :count_in_states
        
        # Calculates all records in a given set of states.
        # 
        # Options:
        # * +operation+ - What operation to use to calculate the value
        # * +state_names+ - A state name or list of state names to find
        # * +args+ - The rest of the args are passed down to ActiveRecord::Base's +calculate+
        # 
        # == Examples
        # 
        #   Car.calculate_in_state(:sum, :insurance_premium, :parked)
        #   Car.calculate_in_states(:sum, :insurance_premium, :parked, :idle)
        #   Car.calculate_in_state(:sum, :insurance_premium, :parked, :conditions => ['highway_id = ?', 1])
        def calculate_in_states(operation, column_name, *args)
          with_state_scope(args) do |options|
            calculate(operation, column_name, options)
          end
        end
        alias_method :calculate_in_state, :calculate_in_states
        
        # Creates a :find scope for matching certain state names.  We can't use
        # the cached records or check if the states are real because subclasses
        # which add additional states may not necessarily have been added yet.
        def with_state_scope(args)
          options = extract_options_from_args!(args)
          state_names = Array(args).map(&:to_s)
          if state_names.size == 1
            state_conditions = ['states.name = ?', state_names.first]
          else
            state_conditions = ['states.name IN (?)', state_names]
          end
          
          with_scope(:find => {:include => :state, :conditions => state_conditions}) do
            yield options
          end
        end
        
        # Checks whether the given name is an active event in the system.  +name+
        # can either be a Symbol or String.
        def active_event?(name)
          active_events.keys.include?(name.to_sym)
        end
        
        private
        # Defines a state or multiple states of the system. This can take an optional
        # hash that defines callbacks which should be invoked when the object
        # enters/exits the state.
        # 
        # Configuration options:
        # * +before_enter+ - Invoked before the state has been entered
        # * +after_enter+ - Invoked after the state has been entered
        # * +before_exit+ - Invoked before the state has been exited (transitioning to a new state)
        # * +after_exit+ - Invoked after the state has been exited
        # 
        # Each of the above configuration options can take the same parameters
        # used for +if+ options in validations (such as String, Symbol, Proc,
        # etc.).  You can also define the callback yourself as shown in the
        # example further down.
        # 
        # == Callback order
        # 
        # These callbacks are invoked in the following order:
        # 1. before_exit (old state)
        # 2. before_enter (new state)
        # 3. after_exit (old state)
        # 4. after_enter (new state)
        # 
        # == Class methods
        # 
        # The following *class* methods are generated when a new state is created
        # (the "parked" state is used as an example):
        # * <tt>parked(*args)</tt> - Finder for all records with a +parked+ state
        # * <tt>parked_count(*args)</tt> - Counts the number of records in the +parked+ state
        # 
        # == Instance methods
        # 
        # The following *instance* methods are generated when a new state is created
        # (the "parked" state is used as an example):
        # * <tt>parked?</tt> - Whether or not the record is currently in the parked state
        # * <tt>parked_at(count = :last)</tt> - Finds the time at which the record was last in the parked state.  Valid options include :first, :last, and :all.
        # 
        # == Example
        #
        #   class Car < ActiveRecord::Base
        #     has_states :initial => :parked
        #     
        #     state :parked, :idling
        #     state :first_gear, :before_enter => :put_on_seatbelt
        #     
        #     def before_exit_first_gear
        #       puts "about to exit :first_gear"
        #     end
        #   end
        def state(*names)
          options = extract_options_from_args!(names)
          
          names.each do |name|
            name = name.to_sym
            
            if active_states[name]
              raise StateAlreadyActive, "#{self} state with name=#{name.to_s.inspect} has already been defined"
            elsif record = states.find_by_name(name.to_s, :readonly => true)
              active_states[name] = ActiveState.new(self, record, options)
            else
              raise StateNotFound, "Couldn't find #{self} state with name=#{name.to_s.inspect}"
            end
          end
        end
        
        # Defines an event of the system.  This can take an optional hash that
        # defines callbacks which should be invoked when the object enters/exits
        # the event.
        # 
        # Configuration options:
        # * +before+ - Invoked before the event has been executed
        # * +after+ - Invoked after the event has been executed
        # 
        # Each of the above configuration options can take the same parameters
        # used for +if+ options in validations (such as String, Symbol, Proc,
        # etc.).  You can also define the callback yourself as shown in the
        # example further down.
        # 
        # == Callback order
        # 
        # These callbacks are invoked in the following order:
        # 1. before
        # 2. after
        # 
        # == Instance methods
        # 
        # The following *instance* methods are generated when a new event is created
        # (the "park" state is used as an example):
        # * <tt>park!(*args)</tt> - Fires the "park", transitioning from the current state to the next valid state.  This takes an optional +args+ list which is passed to the event callbacks.
        # 
        # == Defining transitions
        # 
        # +event+ requires a block which allows you to define the possible
        # transitions that can happen as a result of that event.  For example,
        # 
        #   event :park do
        #     transition_to :parked, :from => :idle
        #   end
        #   
        #   event :first_gear do
        #     transition_to :first_gear, :from => :parked, :if => :seatbelt_on?
        #   end
        # 
        # See PluginAWeek::Has::States::ActiveEvent#transition_to for more
        # information on the possible options that can be passed in.
        # 
        # == Example
        # 
        #   class Car < ActiveRecord::Base
        #     has_states :initial => :parked
        #     
        #     state :parked, :first_gear, :reverse
        #     
        #     event :park, :after => :release_seatbelt do
        #       transition_to :parked, :from => [:first_gear, :reverse]
        #     end
        #   end
        def event(name, options = {}, &block)
          name = name.to_sym
          
          record = events.find_by_name(name.to_s, :readonly => true)
          raise EventNotFound, "Couldn't find #{self} event with name=#{name.to_s.inspect}" unless record
          
          active_events[name] ||= ActiveEvent.new(self, record, options)
          active_events[name].instance_eval(&block) if block
        end
      end
      
      module InstanceMethods
        def self.included(base) #:nodoc:
          base.class_eval do
            alias_method_chain :state, :initial_check
          end
        end
        
        # Gets the name of the initial state that records will be placed in.
        def initial_state_name
          name = self.class.read_inheritable_attribute(:initial_state)
          name = name.call(self) if name.is_a?(Proc)
          
          name.to_sym
        end
        
        # Gets the actual record for the initial state
        def initial_state
          self.class.active_states[initial_state_name].record
        end
        
        # Gets the state of the record.  If this record has not been saved, then
        # the initial state will be returned.
        def state_with_initial_check(*args)
          state_id = read_attribute(:state_id)
          (new_record? && (!state_id || state_id == 0) ? initial_state : nil) || state_without_initial_check(*args)
        end
        
        # Gets the state id of the record.  If this record has not been saved,
        # then the id of the initial state will be returned.
        def state_id
          state_id = read_attribute(:state_id)
          (new_record? && (!state_id || state_id == 0) ? initial_state.id : nil) || state_id
        end
        
        # Returns what the next state for a given event would be, as a Ruby symbol
        def next_state_for_event(name)
          next_states = next_states_for_event(name)
          next_states.empty? ? nil : next_states.first
        end
        
        # Returns all of the next possible states for a given event, as Ruby symbols.
        def next_states_for_event(name)
          event = self.class.active_events[name.to_sym]
          raise StateNotActive, "Couldn't find active #{self.class.name} state with name=#{name.to_s.inspect}" unless event
          
          event.possible_transitions_from(self.state).map(&:to_state).map(&:record)
        end
        
        private
        # Records the state change in the database
        def record_state_change(event, from_state, to_state)
          if self.class.record_state_changes
            state_change = state_changes.build
            state_change.to_state = to_state.record
            state_change.from_state = from_state.record if from_state
            state_change.event = event.record if event
            
            state_change.save!
          end
        end
        
        # Sets the initial state id of the record so long as it hasn't already
        # been set
        def set_initial_state_id
          self.state_id = state.id if [0, nil].include?(read_attribute(:state_id))
        end
        
        # Records the transition for the record going into its initial state
        def run_initial_state_actions
          if state_changes.empty?
            transaction do
              state = self.class.active_states[initial_state_name]
              callback("after_enter_#{state.name}")
              
              record_state_change(nil, nil, state)
            end
          end
        end
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  include PluginAWeek::Has::States
end
