describe TestAggregation::ClassResult do
  let(:build_result) do
    res = double('BuildResult',
                 find_job: 1,
                 step_result_callback: ->(step) { step[:result] },
                 test_case_result: 'Created')

    allow(res).to receive(:aggregate_by).with(anything).and_return('machine')
    res
  end
  let(:subject) { TestAggregation::ClassResult.new(build_result) }

  describe '#class_results_hash' do
    it 'sums individual step results counts form test_steps#results_hash' do
      test_step1 = double('test_step', results_hash: { 'passed' => 1, 'created' => 2 })
      test_step2 = double('test_step', results_hash: { 'failed' => 1, 'created' => 3 })
      expect(subject).to receive(:test_steps).and_return([test_step1, test_step2])

      expect(subject.class_results_hash).to eq('passed' => 1, 'failed' => 1, 'created' => 5)
    end
  end

  describe '#parse' do
    it 'raises exception when class_name is not defined' do
      expect do
        subject.parse({})
      end.to raise_error(/Class name not defined/)
    end

    it 'raises exception when class_name differs' do
      subject.parse('class_name' => 'CN1', 'position' => 1, 'name' => 'N', 'result' => 'passed')
      expect do
        subject.parse('class_name' => 'CN2', 'position' => 1, 'name' => 'N', 'result' => 'passed')
      end.to raise_error(/Class name mismatch/)
    end

    it 'raises exception when position is not defined' do
      expect do
        subject.parse('class_name' => 'CN2', 'name' => 'N')
      end.to raise_error(/Step position is undefined/)
    end

    it 'creates instance of StepResult on passed position' do
      subject.parse('class_name' => 'CN1', 'position' => 3, 'name' => 'N', 'result' => 'passed')
      expect(subject.test_steps[2]).to be_kind_of(TestAggregation::StepResult)
    end

    it 'calls #parse(step) for StepResult instance' do
      subject.parse('class_name' => 'CN1', 'position' => 3, 'name' => 'N', 'result' => 'passed')
      expect(subject.test_steps[2]).to receive(:parse)
      subject.parse('class_name' => 'CN1', 'position' => 3, 'name' => 'N', 'result' => 'passed')
    end
  end

  describe '#as_json' do
    it 'returns `description` key' do
      expect(subject).to receive(:name).and_return 'NAME1'
      expect(subject.as_json[:description]).to eq 'NAME1'
    end

    it 'delegate to test_steps#as_json' do
      expect(subject).to receive(:test_steps).twice.and_return(
        [double('test_steps', as_json: { mock: true }, results_hash: {})]
      )
      expect(subject.as_json[:testSteps]).to eq [{ mock: true }]
    end
  end
end
