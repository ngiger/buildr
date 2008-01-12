require 'core/build'
require 'core/compile'
require 'java/ant'
require 'core/help'


module Buildr

  # JMock is available when using JUnit and TestNG.
  module JMock
    # JMock version.
    VERSION = '1.2.0' unless const_defined?('VERSION')
    # JMock specification.
    REQUIRES = ["jmock:jmock:jar:#{VERSION}"]
  end


  # JUnit test framework, the default test framework for Java tests.
  #
  # Support the following options:
  # * :fork        -- If true/:once (default), fork for each test class.  If :each, fork for each individual
  #                   test case.  If false, run all tests in the same VM (fast, but dangerous).
  # * :clonevm     -- If true clone the VM each time it is forked.
  # * :properties  -- Hash of system properties available to the test case.
  # * :environment -- Hash of environment variables available to the test case.
  # * :java_args   -- Arguments passed as is to the JVM.
  class JUnit < TestFramework::Base

    # Used by the junit:report task. Access through JUnit#report if you want to set various
    # options for that task, for example:
    #   JUnit.report.frames = false
    class Report

      # Ant-Trax required for running the JUnitReport task.
      Java.classpath << "org.apache.ant:ant-trax:jar:#{Ant::VERSION}"

      # Parameters passed to the Ant JUnitReport task.
      attr_reader :params
      # True (default) to produce a report using frames, false to produce a single-page report.
      attr_accessor :frames
      # Directory for the report style (defaults to using the internal style).
      attr_accessor :style_dir
      # Target directory for generated report.
      attr_accessor :target

      def initialize
        @params = {}
        @frames = true
        @target = 'reports/junit'
      end

      # :call-seq:
      #   generate(projects, target?)
      #
      # Generates a JUnit report for these projects (must run JUnit tests first) into the
      # target directory. You can specify a target, or let it pick the default one from the
      # target attribute.
      def generate(projects, target = @target.to_s)
        html_in = File.join(target, 'html')
        rm_rf html_in ; mkpath html_in
        
        Buildr.ant('junit-report') do |ant|
          ant.junitreport :todir=>target do
            projects.select { |project| project.test.framework == :junit }.
              map { |project| project.test.report_to.to_s }.select { |path| File.exist?(path) }.
              each { |path| ant.fileset(:dir=>path) { ant.include :name=>'TEST-*.xml' }  }
            options = { :format=>frames ? 'frames' : 'noframes' }
            options[:styledir] = style_dir if style_dir
            ant.report options.merge(:todir=>html_in) do
              params.each { |key, value| ant.param :name=>key, :expression=>value }
            end
          end
        end
      end

    end

    class << self

      # :call-seq:
      #    report()
      #
      # Returns the Report object used by the junit:report task. You can use this object to set
      # various options that affect your report, for example:
      #   JUnit.report.frames = false
      #   JUnit.report.params['title'] = 'My App'
      def report
        @report ||= Report.new
      end

    end


    # Ant-JUnit requires for JUnit and JUnit reports tasks.  Also requires JUnitTestFilter.
    Java.classpath << "org.apache.ant:ant-junit:jar:#{Ant::VERSION}" << File.join(File.dirname(__FILE__))

    # JUnit version number.
    VERSION = '4.3.1' unless const_defined?('VERSION')
    # JUnit specification.
    REQUIRES = ["junit:junit:jar:#{VERSION}"] + JMock::REQUIRES

    class << self

      def applies_to?(project) #:nodoc:
        project.test.compile.language == :java
      end

    end

    def tests(project) #:nodoc:
      return [] unless project.test.compile.target
      target = Pathname.new(project.test.compile.target.to_s)
      candidates = Dir["#{target}/**/*.class"].
        map { |file| Pathname.new(file).relative_path_from(target).to_s.ext('').gsub(File::SEPARATOR, '.') }.
        reject { |name| name =~ /\$/ }
      classpath = [target.to_s + '/'] + Buildr.artifacts(dependencies).map(&:to_s)
      Java.org.apache.buildr.JUnitTestFilter.new(classpath).filter(candidates)
    end

    def run(tests, task, dependencies) #:nodoc:
      # Use Ant to execute the Junit tasks, gives us performance and reporting.
      Buildr.ant('junit') do |ant|
        case options[:fork]
        when false
          forking = {}
        when :each
          forking = { :fork=>true, :forkmode=>'perTest' }
        when true, :once
          forking = { :fork=>true, :forkmode=>'once' }
        else
          fail 'Option fork must be :once, :each or false.'
        end
        mkpath task.report_to.to_s
        ant.junit forking.merge(:clonevm=>options[:clonevm] || false, :dir=>task.send(:project).path_to) do
          ant.classpath :path=>dependencies.each { |path| file(path).invoke }.join(File::PATH_SEPARATOR)
          (options[:properties] || []).each { |key, value| ant.sysproperty :key=>key, :value=>value }
          (options[:environment] || []).each { |key, value| ant.env :key=>key, :value=>value }
          java_args = options[:java_args] || Buildr.options.java_args
          java_args = java_args.split(/\s+/) if String === java_args
          java_args.each { |value| ant.jvmarg :value=>value } if java_args
          ant.formatter :type=>'plain'
          ant.formatter :type=>'plain', :usefile=>false # log test
          ant.formatter :type=>'xml'
          ant.batchtest :todir=>task.report_to.to_s, :failureproperty=>'failed' do
            ant.fileset :dir=>task.compile.target.to_s do
              tests.each { |test| ant.include :name=>File.join(*test.split('.')).ext('class') }
            end
          end
        end
        return tests unless ant.project.getProperty('failed')
      end
      # But Ant doesn't tell us what went kaput, so we'll have to parse the test files.
      tests.inject([]) do |passed, test|
        report_file = File.join(task.report_to.to_s, "TEST-#{test}.txt")
        if File.exist?(report_file)
          report = File.read(report_file)
          # The second line (if exists) is the status line and we scan it for its values.
          status = (report.split("\n")[1] || '').scan(/(run|failures|errors):\s*(\d+)/i).
            inject(Hash.new(0)) { |hash, pair| hash[pair[0].downcase.to_sym] = pair[1].to_i ; hash }
          passed << test if status[:failures] == 0 && status[:errors] == 0
        end
        passed
      end
    end

    namespace 'junit' do
      desc "Generate JUnit tests report in #{report.target}"
      task('report') do |task|
        report.generate Project.projects
        puts "Generated JUnit tests report in #{report.target}" if verbose
      end
    end

    task('clean') { rm_rf report.target.to_s }

  end


  # TestNG test framework.  To use in your project:
  #   test.using :testng
  #
  # Support the following options:
  # * :properties -- Hash of properties passed to the test suite.
  # * :java_args -- Arguments passed to the JVM.
  class TestNG < TestFramework::Base

    # TestNG version number.
    VERSION = '5.5' unless const_defined?('VERSION')
    # TestNG specification.
    REQUIRES = ["org.testng:testng:jar:jdk15:#{VERSION}"] + JMock::REQUIRES
    # Pattern for selecting TestNG test classes. Regardless of include/exclude patterns, only classes
    # that match this pattern are used.
    TESTS_PATTERN = [ /^Test/, /Test$/, /TestCase$/ ]

    class << self

      def applies_to?(project) #:nodoc:
        project.test.compile.language == :java
      end

    end

    def tests(project) #:nodoc:
      return [] unless project.test.compile.target
      target = Pathname.new(project.test.compile.target.to_s)
      Dir["#{target}/**/*.class"].
        map { |file| Pathname.new(file).relative_path_from(target).to_s.ext('').gsub(File::SEPARATOR, '.') }.
        reject { |name| name =~ /\$/ }.select { |name| cls_name = name.split('.').last
                                                       TESTS_PATTERN.any? { |pattern| cls_name =~ pattern } }
    end

    def run(tests, task, dependencies) #:nodoc:
      cmd_args = [ 'org.testng.TestNG', '-sourcedir', task.compile.sources.join(';'), '-suitename', task.send(:project).name ]
      cmd_args << '-d' << task.report_to.to_s
      cmd_options = { :properties=>options[:properties], :java_args=>options[:java_args],
                      :classpath=>dependencies }
      tests.inject([]) do |passed, test|
        begin
          Buildr.java cmd_args, '-testclass', test, cmd_options.merge(:name=>test)
          passed << test
        rescue
          passed
        end
      end
    end

  end

end


Buildr::TestFramework << Buildr::JUnit
Buildr::TestFramework << Buildr::TestNG
