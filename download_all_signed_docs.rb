#!/usr/bin/env ruby
#
# download_all_signed_docs_with_titles.rb
#
# Uses HTTParty to:
#   1) Fetch every signature_request_id (along with its title) via the HelloSign API (paginated)
#   2) Download the combined PDF for each request
#   3) Save each PDF using a sanitized version of the "title" (envelope name)
#
# Adds retry logic with exponential backoff for rate limit (HTTP 429) responses.
#
# This script is compatible with Ruby 2.7.0.
#
# Usage:
#   $ chmod +x download_all_signed_docs_with_titles.rb
#   $ ./download_all_signed_docs_with_titles.rb
#
# Make sure HELLOSIGN_API_KEY is set in your environment before running.

require 'json'
require 'fileutils'
require 'uri'

class FileDownloadStatus
  attr_reader :id, :title, :filename, :state, :error_message

  STATES = [:pending, :downloading, :success, :error, :skipped]

  def initialize(id:, title:)
    @id = id
    @title = title
    @state = :pending
    @filename = nil
    @error_message = nil
  end

  def start_download
    @state = :downloading
  end

  def mark_success(filename)
    @state = :success
    @filename = filename
  end

  def mark_error(error_message)
    @state = :error
    @error_message = error_message
  end

  def skip(reason)
    @state = :skipped
    @error_message = reason
  end

  def to_h
    {
      id: @id,
      title: @title,
      filename: @filename,
      state: @state,
      error_message: @error_message
    }
  end
end

class HelloSignDownloader
  DEFAULT_BASE_URL      = 'https://api.hellosign.com/v3'
  DEFAULT_PAGE_SIZE     = 100
  DEFAULT_MAX_RETRIES   = 5
  DEFAULT_INITIAL_SLEEP = 1

  attr_reader :api_key, :base_url, :page_size, :output_folder, :max_retries, :initial_sleep, :statuses
  attr_accessor :http_client

  def self.default_http_client
    require 'httparty'
    HTTParty
  end

  def initialize(api_key: ENV['HELLOSIGN_API_KEY'] || 'PUT_YOUR_API_KEY_HERE',
                 base_url: DEFAULT_BASE_URL,
                 page_size: DEFAULT_PAGE_SIZE,
                 output_folder: nil,
                 max_retries: DEFAULT_MAX_RETRIES,
                 initial_sleep: DEFAULT_INITIAL_SLEEP,
                 http_client: self.class.default_http_client)
    @timestamp    = Time.now.to_i
    @output_folder = output_folder || File.expand_path("./signed_docs_#{@timestamp}")
    @api_key       = api_key
    @base_url      = base_url
    @page_size     = page_size
    @max_retries   = max_retries
    @initial_sleep = initial_sleep
    @http_client   = http_client
    @auth          = { username: @api_key, password: '' }
    FileUtils.mkdir_p(@output_folder)
    @statuses      = []
  end

  def download_all_signed_docs
    puts "Using HelloSign API Key: #{api_key[0..3]}..."
    puts "Output folder: #{output_folder}"
    puts

    total_pages = fetch_total_pages
    puts "Total pages available: #{total_pages}"
    puts

    all_requests = collect_all_requests(total_pages)
    puts
    puts "Collected a total of #{all_requests.size} signature_request(s)."
    puts

    @statuses.clear
    
    all_requests.each_with_index do |req, idx|
      status = FileDownloadStatus.new(id: req[:id], title: req[:title])
      @statuses << status
      sig_id    = req[:id]
      raw_title = req[:title]
      begin
        status.start_download
        print "Downloading PDF [#{idx+1}/#{all_requests.size}] for ID=#{sig_id}... "
        file_resp = download_with_retry(
          "#{base_url}/signature_request/files/#{URI.encode_www_form_component(sig_id)}",
          { file_type: 'pdf' }
        )
        if file_resp.code == 200
          filename_base = sanitize_filename(raw_title, sig_id)
          filename = File.join(output_folder, "#{filename_base}.pdf")
          File.open(filename, 'wb') { |f| f.write(file_resp.body) }
          status.mark_success(filename)
          puts "saved to #{filename}."
        else
          msg = "HTTP #{file_resp.code}. Skipping."
          status.mark_error(msg)
          puts msg
        end
      rescue StandardError => e
        status.mark_error(e.message)
        puts "failed (#{e.message})"
      end
    end
    puts
    puts "Done! Check #{output_folder} for your signed documents."
    print_status_summary
  end

  def fetch_total_pages
    puts "Fetching first page of signature requests to get pagination info..."
    first_response = http_client.get(
      "#{base_url}/signature_request/list",
      basic_auth: @auth,
      query: { page: 1, page_size: page_size }
    )
    unless first_response.code == 200
      abort("Failed to fetch signature_request list (HTTP #{first_response.code})\n" \
            "Response body: #{first_response.body}")
    end
    parsed = JSON.parse(first_response.body)
    list_info = parsed['list_info']
    list_info['num_pages'].to_i
  end

  def collect_all_requests(total_pages)
    all_requests = []
    (1..total_pages).each do |page_num|
      print "Fetching page #{page_num}/#{total_pages}... "
      resp = http_client.get(
        "#{base_url}/signature_request/list",
        basic_auth: @auth,
        query: { page: page_num, page_size: page_size }
      )
      if resp.code != 200
        warn "Page #{page_num} returned HTTP #{resp.code}. Skipping."
        next
      end
      body = JSON.parse(resp.body)
      signatures = body['signature_requests'] || []
      puts "got #{signatures.size} request(s)."
      signatures.each do |sig|
        envelope_title = sig['title'] || ""
        all_requests << { id: sig['signature_request_id'], title: envelope_title }
      end
    end
    all_requests
  end

  def sanitize_filename(raw_title, fallback_id)
    name = raw_title.to_s.strip.empty? ? fallback_id : raw_title.dup
    safe = name.gsub(/[^0-9A-Za-z.\-]/, '_')
    safe = fallback_id if safe.strip.empty?
    safe
  end

  def download_with_retry(url, params)
    retries = 0
    sleep_time = initial_sleep
    while retries <= max_retries
      begin
        response = http_client.get(url, basic_auth: @auth, query: params)
        if response.code == 429
          if retries < max_retries
            warn "Rate limit hit (429). Retrying in #{sleep_time}s..."
            sleep(sleep_time)
            retries += 1
            sleep_time *= 2
            next
          else
            abort("Exceeded max retries for #{url}")
          end
        end
        return response
      rescue StandardError => e
        if retries < max_retries
          warn "Exception encountered: #{e.message}. Retrying in #{sleep_time}s..."
          sleep(sleep_time)
          retries += 1
          sleep_time *= 2
          next
        else
          abort("Exceeded max retries due to exception for #{url}: #{e.message}")
        end
      end
    end
  end

  def print_status_summary
    puts "\nSummary of file downloads:"
    @statuses.each_with_index do |status, idx|
      puts "[#{idx+1}] ID=#{status.id}, Title=\"#{status.title}\", State=#{status.state}, File=#{status.filename}, Error=#{status.error_message}"
    end
  end

  def write_statuses_to_json
    filename = File.join(@output_folder, "download_status_#{@timestamp}.json")
    data = @statuses.map(&:to_h)
    File.open(filename, 'w') do |f|
      f.write(JSON.pretty_generate(data))
    end
    puts "Status written to #{filename}"
  end

  def statuses
    @statuses
  end
end

if __FILE__ == $0
  downloader = HelloSignDownloader.new
  begin
    downloader.download_all_signed_docs
  rescue Interrupt
    puts "\nInterrupted by user."
  ensure
    downloader.print_status_summary
    downloader.write_statuses_to_json
  end
end

# End of script