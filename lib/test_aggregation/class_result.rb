require 'test_aggregation/step_result'
require 'tsort'
require 'pp'

# EXTEND HASH BY TSORT
class Hash
  include TSort

  alias tsort_each_node each_key

  def tsort_each_child(node, &block)
    fetch(node).each(&block)
  end
end

module TestAggregation
  # class representing test case
  class ClassResult
    attr_reader :build_result
    attr_reader :test_steps
    attr_reader :name, :position
    attr_reader :static_steps_count

    def initialize(build_result)
      @build_result = build_result
      @test_steps = []
      @added_steps = []
      @static_steps_count = 0
    end

    def step_result_callback
      build_result.step_result_callback
    end

    def find_job(job_id)
      build_result.find_job(job_id)
    end

    def class_results_hash(opts = {})
      # TODO: include added steps
      test_steps.each_with_object({}) do |step, obj|
        next unless step

        step_result = step.results_hash(opts)
        step_result.each do |state_name, state_value|
          obj[state_name] ||= 0
          obj[state_name] += state_value
        end
      end
    end

    def parse(step)
      # store added steps to process them later
      if step['added_step'] == true
        @added_steps << step
        return
      end

      # FIXME: use only class_name
      class_name = step['class_name'] || step['classname']

      raise "Class name not defined for step: #{step.inspect}" unless class_name

      if name && name != class_name
        raise "Class name mismatch: current=#{name}, step.class_name=#{class_name}"
      end

      @name ||= class_name
      @position ||= step['class_position']

      step_position = step['position']
      raise "Step position is undefined. Cannot parse step: #{step.inspect}" unless step_position

      step_position = step_position.to_i - 1

      @test_steps[step_position] ||= StepResult.new(self)
      @test_steps[step_position].parse(step)
      @static_steps_count = @test_steps.count
    end

    def normalized_test_steps
      # copy results of non-added steps to output
      # normalized_steps = @test_steps.map do |test_step|
      #   next unless test_step
      #   test_step.as_json
      # end
      preprocessed_steps = preprocess_steps

      begin
        sorted_step_names = preprocessed_steps.tsort

        generate_data_for_added_steps(sorted_step_names)
      rescue TSort::Cyclic
        generate_data_for_cyclic_added_steps
      end

      @test_steps.map do |test_step|
        next unless test_step
        test_step.as_json
      end

      #normalized_steps
    end

    def as_json
      {
        description: name,
        result: build_result.test_case_result(class_results_hash),
        testSteps: normalized_test_steps
      }
    end

    private

    def job_ids
      @added_steps.map{ |as| as['job_id'] }.uniq
    end

    # returns preprocess added step data:
    # we need to take only names and generate ordered list
    # data are stored in following structure
    # Example:
    # machineA = ['stepA', 'stepB', 'stepC']
    # machineB = ['stepD''stepE', 'stepC']
    # preprocessed data: [
    #   'stepA' => [],
    #   'stepB' => ['stepA'],
    #   'stepC' => ['stepA', 'stepB', 'stepD', 'stepE'],
    #   'stepD' => [],
    #   'stepE' => ['stepD'],
    # ]
    def preprocess_steps
      job_ids.each_with_object({}) do |job_id, preprocessed_hash_result|

        steps_by_job_id = job_filtered_steps(job_id)

        # gather all step names in current job
        step_names = steps_by_job_id.map { |sbji| sbji['name'] }

        step_names.uniq! # TODO: needed?

        # generate data with dependency
        step_names.each_with_index do |ms, i|
          preprocessed_hash_result[ms] ||= []
          step_names.take(i).each { |name| preprocessed_hash_result[ms] << name }
        end

        # uniq the ancestors
        preprocessed_hash_result.each { |_key, value| value.uniq! }
      end
    end

    def format_added_steps(sorted)
      #position = 1

      sorted.each_with_object([]) do |s, formated_added_steps|
        # all_states = results.each_with_object([]) do |(_machine, value), result|
        #   result << build_result.step_status_rewrite_callback(value)
        # end

        all_machines = {
          'all' => {
            result: 'Passed', # TODO: compute all machines result
            message: '',
            resultId: '00000000-0000-0000-0000-000000000000'
          }
        }

        added_machines = job_ids.each_with_object({}) do |job_id, result|
          step_result_for_machine = @added_steps.find { |sbf| sbf['job_id'] == job_id && sbf['name'] == s }

          step_obj = if step_result_for_machine
            { result: step_result_for_machine['result'], data: step_result_for_machine['data'] }
          else
            { data: { 'status' => 'not_performed' } }
          end

          job = find_job(job_id)

          result[build_result.aggregate_by(job)] = {
            result: build_result.step_status_rewrite_callback(step_obj),
            message: '',
            resultId: job_id
          }
        end

        added_machines.merge(all_machines)

        formated_added_steps << {
          id: __id__, # temporary id until we can put here vCenter machine id
          description: s,
          machines: added_machines
        }
      end
    end

    def generate_data_for_cyclic_added_steps
      step_position = static_steps_count
      @test_steps = @test_steps[0..static_steps_count]

      job_ids.each do |job_id|

        steps_by_job_id = job_filtered_steps(job_id)
        steps_by_job_id.each do |step|
          job_ids.each do |generate_for_job_id|
            @test_steps[step_position] ||= StepResult.new(self)

            @test_steps[step_position].parse(
              generate_for_job_id == job_id ? step :
              not_performed_step(generate_for_job_id, step['name'])
            )

          end

          step_position = step_position + 1
        end
      end
    end

    def generate_data_for_added_steps(sorted)
      step_position = static_steps_count
      @test_steps = @test_steps[0..static_steps_count]

      sorted.each do |step_name|
        job_ids.each do |generate_for_job_id|
          @test_steps[step_position] ||= StepResult.new(self)

          found_result = @added_steps.find do |item|
            item['job_id'] == generate_for_job_id &&
            item['name'] == step_name
          end

          if found_result
            @test_steps[step_position].parse(found_result)
          else
            mocked_step = not_performed_step(
              generate_for_job_id,
              step_name
            )

            @test_steps[step_position].parse(mocked_step)
          end
        end

        step_position += 1
      end
    end

    def not_performed_step(job_id, name)
      {
        'uuid' => '00000000-1001-1111-1001-000000000000',
        'job_id' => job_id,
        'name' => name,
        #'position': step_position,
        #'classname': name,
        #'class_position': position,
        'result' => 'pending',
        'data'=> { 'status' => 'not_performed', 'imported' => true },
        'number'=> 1
      }
    end

    def results_without_created
      StepResult::RESULTS.reject { |a| a == 'created' }
    end

    # filters out results and takes only step results: passed, failed, ...
    def job_filtered_steps(job_id)
      steps_by_job_id = @added_steps.find_all { |s| s['job_id'] == job_id }.sort_by { |s| s['position'] }
      grouped = steps_by_job_id.group_by { |sbji| sbji['uuid'] }

      pp "#{grouped.class}"

      grouped.each_with_object([]) do |(_uuid, step_group), result|
        result << step_group.max_by { |step_results| step_results['number'] }
      end
    end
  end
end
