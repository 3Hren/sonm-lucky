#!/usr/bin/env ruby

require 'optparse'
require 'tempfile'
require 'yaml'
require 'json'
require 'rbconfig'

def run_cmd(&block)
  output = yield block
  raise "[#{$?.exitstatus}]: #{output}" unless $?.exitstatus == 0
  output
end

def run(what, &block)
  puts "[ .. ] #{what}"
  r = yield block
  puts "\033[F\r[ \e[32mOK\e[0m ] #{what} - #{r}"
  r
rescue Exception => err
  puts "\033[F\r[\e[31mFAIL\e[0m] #{what} - #{err}"
  exit 1
end

def detect_cli_path
  run 'Detecting sonmcli path' do
    _detect_cli_path
  end
end

def _detect_cli_path
  os = RbConfig::CONFIG['host_os']
  if os.start_with? 'darwin'
    os = os[0..-3]
  end

  arch = RbConfig::CONFIG['host_cpu']

  filename = "sonmcli_#{os}_#{arch}"

  path = %x[which #{filename}]
  if $?.exitstatus == 0
    return File.join(path, filename)
  end

  env = ENV.to_h
  repo = '/src/github.com/sonm-io/core/target'
  if env['GOPATH'] != nil
    return File.join(env['GOPATH'], repo, filename)
  end

  File.join(env['HOME'], 'go', repo, filename)
end

class Lucky
  def initialize(node_endpoint)
    @cli = detect_cli_path + " --node=#{node_endpoint}"
  end

  def start
    check_worker_running
    ask_plan_id = create_ask_plan
    ask_order_id = get_order_id ask_plan_id
    bid_order_id = create_bid_order
    deal_id = open_deal ask_order_id, bid_order_id
    check_deal_status deal_id
    task_id = start_task deal_id
    task_status deal_id, task_id
    task_stop deal_id, task_id
  end

  private

  def check_worker_running
    run 'Checking Worker is running' do
      run_cmd do
        %x[#{@cli} worker status]
      end
    end
  end

  def create_ask_plan
    template = {
      duration: '1h',
      price: '1000 SNM/h',
      resources: {
        cpu: {
          cores: 0.01,
        },
        ram: {
          size: '5MB',
        },
        storage: {},
        gpu: {
          indexes: [],
        },
        network: {
          throughputin: '0 Mbit/s',
          throughputout: '0 Mbit/s',
          overlay: true,
          outbound: true,
          incoming: false,
        },
      },
    }

    run 'Create ask-plan' do
      file = Tempfile.new('ask-plan.yaml')
      begin
        file.write(template.to_json)
        file.close

        output = run_cmd do
          %x[#{@cli} worker ask-plan create #{file.path}]
        end
        m = /ID = (?<id>.*)/.match(output)
        m[:id].strip
      ensure
         file.unlink
      end
    end
  end

  def get_order_id(ask_plan_id)
    run 'Obtain ASK order ID' do
      order_id = nil
      loop do
        output = run_cmd do
          %x[#{@cli} worker ask-plan list]
        end

        content = YAML.load output
        order_id = content[ask_plan_id]['orderid']
        if order_id != nil && order_id != ''
          break
        end
        sleep 1.0
      end

      order_id
    end
  end

  def create_bid_order
    template = {
      duration: '1h',
      price: '1000 SNM/h',
      resources: {
        network: {
          overlay: true,
          outbound: false,
          incoming: false,
        },
        benchmarks: {
          'ram-size': 5000000,
          'cpu-cores': 4,
          'cpu-sysbench-single': 0,
          'cpu-sysbench-multi': 0,
          'net-download': 0,
          'net-upload': 0,
          'gpu-count': 0,
          'gpu-mem': 0,
          'gpu-eth-hashrate': 0,
        },
      },
    }

    run 'Create BID order' do
      file = Tempfile.new('bid-plan.yaml')
      begin
        file.write(template.to_json)
        file.close

        output = run_cmd do
          %x[#{@cli} market create #{file.path}]
        end

        m = /ID = (?<id>.*)/.match(output)
        m[:id].strip
      ensure
         file.unlink
      end
    end
  end

  def open_deal(ask_order_id, bid_order_id)
    run 'Open deal' do
      output = run_cmd do
        %x[#{@cli} deals open #{ask_order_id} #{bid_order_id}]
      end

      m = /\s*?ID = (?<id>.*)/.match(output)
      m[:id].strip
    end
  end

  def check_deal_status(deal_id)
    run 'Check deal status' do
      output = run_cmd do
        %x[#{@cli} deals status #{deal_id} --out=json]
      end

      output = JSON.parse output
      output['id']
      raise 'failed' unless output['id'] == deal_id

      'OK'
    end
  end

  def start_task(deal_id)
    template = {
      task: {
        container: {
          commit_on_stop: true,
          name: 'httpd:latest',
          env: {},
        },
      },
    }

    run 'Start task' do
      file = Tempfile.new('task.yaml')
      begin
        file.write(template.to_json)
        file.close

        output = run_cmd do
          %x[#{@cli} tasks start #{deal_id} #{file.path} --out=json]
        end

        output = JSON.parse output
        output['id']
      ensure
         file.unlink
      end
    end
  end

  def worker_id_by_deal_id(deal_id)
    output = run_cmd do
      %x[#{@cli} deals status #{deal_id}]
    end

    YAML.load(output)['Consumer ID'].to_s 16
  end

  def task_status(deal_id, task_id)
    run 'Task status' do
      worker_id = worker_id_by_deal_id deal_id

      run_cmd do
        %x[#{@cli} tasks status #{worker_id} #{task_id}]
      end

      'OK'
    end
  end

  def task_stop(deal_id, task_id)
    run 'Task stop' do
      worker_id = worker_id_by_deal_id deal_id

      run_cmd do
        %x[#{@cli} tasks stop #{worker_id} #{task_id}]
      end

      'OK'
    end
  end
end

def main(node: 'localhost:15030')
  m = Lucky.new node
  m.start
end

options = {}

OptionParser.new do |opts|
  opts.banner = 'SONM Lucky: main.rb [options]'

  opts.on('--node [IP:PORT]', 'Node endpoint') do |v|
    options[:node] = v
  end
end.parse!

main options
