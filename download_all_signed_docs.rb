#!/usr/bin/env ruby
#
# download_all_signed_docs_with_titles.rb
#
# This script downloads all signed documents from your Dropbox Sign (formerly HelloSign) account.
# It saves each document with a readable filename and keeps a status log of every download, so you can easily see which files succeeded or failed.
#
# == Features
# - Downloads every signed document from your Dropbox Sign account.
# - Names each file using the document's title (or envelope name).
# - Handles rate limits (HTTP 429) with automatic retries.
# - Keeps a status log (JSON) of all downloads, including errors.
# - No external Ruby gems required—just standard Ruby!
#
# == Usage
#   $ export HELLOSIGN_API_KEY=your_api_key_here
#   $ ruby download_all_signed_docs.rb
#
# See README.md for more details.

require 'json'
require 'fileutils'
require 'uri'
require 'net/http'

##
# Represents the download status and state for a single file/request.
#
# Tracks the signature request ID, title, filename, current state, and any error message.
# Used by HelloSignDownloader to maintain a status log for all downloads.
class FileDownloadStatus
  # The signature request ID
  attr_reader :id
  # The title of the document/envelope
  attr_reader :title
  # The full path to the saved file (if successful)
  attr_reader :filename
  # The current state (:pending, :downloading, :success, :error, :skipped)
  attr_reader :state
  # The error message, if any
  attr_reader :error_message

  # Possible states for a file download
  STATES = [:pending, :downloading, :success, :error, :skipped]

  ##
  # Create a new FileDownloadStatus
  #
  # id::    The signature request ID
  # title:: The document/envelope title
  def initialize(id:, title:)
    @id = id
    @title = title
    @state = :pending
    @filename = nil
    @error_message = nil
  end

  ##
  # Mark the file as starting download
  def start_download
    @state = :downloading
  end

  ##
  # Mark the file as successfully downloaded
  # filename:: The path to the saved file
  def mark_success(filename)
    @state = :success
    @filename = filename
  end

  ##
  # Mark the file as failed with an error
  # error_message:: The error message
  def mark_error(error_message)
    @state = :error
    @error_message = error_message
  end

  ##
  # Mark the file as skipped
  # reason:: The reason for skipping
  def skip(reason)
    @state = :skipped
    @error_message = reason
  end

  ##
  # Convert the status to a hash for JSON serialization
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

##
# Downloads all signed documents from Dropbox Sign and maintains a status log.
#
# Usage:
#   downloader = HelloSignDownloader.new
#   downloader.download_all_signed_docs
#
# See README.md for setup and usage instructions.
class HelloSignDownloader
  DEFAULT_BASE_URL      = 'https://api.hellosign.com/v3'
  DEFAULT_PAGE_SIZE     = 100
  DEFAULT_MAX_RETRIES   = 5
  DEFAULT_INITIAL_SLEEP = 1

  # The API key used for authentication
  attr_reader :api_key
  # The base URL for the Dropbox Sign API
  attr_reader :base_url
  # The number of requests per page
  attr_reader :page_size
  # The output folder for downloaded files
  attr_reader :output_folder
  # The maximum number of retries for rate limits
  attr_reader :max_retries
  # The initial sleep time for exponential backoff
  attr_reader :initial_sleep
  # The array of FileDownloadStatus objects
  attr_reader :statuses

  ##
  # Create a new HelloSignDownloader
  #
  # api_key::      Dropbox Sign API key (default: ENV['HELLOSIGN_API_KEY'])
  # base_url::     API base URL (default: DEFAULT_BASE_URL)
  # page_size::    Number of requests per page (default: DEFAULT_PAGE_SIZE)
  # output_folder::Output folder for downloads (default: ./signed_docs_<timestamp>)
  # max_retries::  Max retries for rate limits (default: DEFAULT_MAX_RETRIES)
  # initial_sleep::Initial sleep for backoff (default: DEFAULT_INITIAL_SLEEP)
  def initialize(api_key: ENV['HELLOSIGN_API_KEY'] || 'PUT_YOUR_API_KEY_HERE',
                 base_url: DEFAULT_BASE_URL,
                 page_size: DEFAULT_PAGE_SIZE,
                 output_folder: nil,
                 max_retries: DEFAULT_MAX_RETRIES,
                 initial_sleep: DEFAULT_INITIAL_SLEEP)
    @timestamp    = Time.now.to_i
    @output_folder = output_folder || File.expand_path("./signed_docs_#{@timestamp}")
    @api_key       = api_key
    @base_url      = base_url
    @page_size     = page_size
    @max_retries   = max_retries
    @initial_sleep = initial_sleep
    @auth          = { username: @api_key, password: '' }
    FileUtils.mkdir_p(@output_folder)
    @statuses      = []
  end

  ##
  # Main method to download all signed documents and print a summary.
  #
  # Fetches all signature requests, downloads each PDF, and writes a status log.
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
          filename_base = sanitized_filename(raw_title, sig_id)
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

  ##
  # Fetch the total number of pages of signature requests.
  #
  # Returns the number of pages as an integer.
  def fetch_total_pages
    puts "Fetching first page of signature requests to get pagination info..."
    first_response = net_http_get(
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

  ##
  # Collect all signature request IDs and titles from all pages.
  #
  # total_pages:: The total number of pages to fetch
  # Returns an array of hashes: [{ id: ..., title: ... }, ...]
  def collect_all_requests(total_pages)
    all_requests = []
    (1..total_pages).each do |page_num|
      print "Fetching page #{page_num}/#{total_pages}... "
      resp = net_http_get(
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

  ##
  # Sanitize a string to be a safe filename.
  #
  # raw_title::   The original title string
  # id:: The fallback string if the title is empty
  # Returns a safe filename string.
  def sanitized_filename(raw_title, id)
    if raw_title.to_s.strip.empty?
      name = id
    else
      name = raw_title.dup + '_' + id
    end
    safe = name.gsub(/[^0-9A-Za-z.\-]/, '_')
    safe
  end

  ##
  # Download a file with retry logic for rate limits and exceptions.
  #
  # url::    The URL to download
  # params:: Query parameters for the request
  # Returns a response-like object with .code and .body
  def download_with_retry(url, params)
    retries = 0
    sleep_time = initial_sleep
    while retries <= max_retries
      begin
        response = net_http_get(url, basic_auth: @auth, query: params)
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

  ##
  # Perform a GET request using Net::HTTP with optional basic auth and query params.
  #
  # url::        The URL to request
  # basic_auth:: Hash with :username and :password (optional)
  # query::      Hash of query parameters (optional)
  # Returns a Struct with .code (Integer) and .body (String)
  def net_http_get(url, basic_auth: nil, query: {})
    uri = URI(url)
    uri.query = URI.encode_www_form(query) unless query.empty?
    req = Net::HTTP::Get.new(uri)
    if basic_auth
      req.basic_auth(basic_auth[:username], basic_auth[:password])
    end
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    response = http.request(req)
    Struct.new(:code, :body).new(response.code.to_i, response.body)
  end

  ##
  # Print a summary of all file download statuses to the console.
  def print_status_summary
    puts "\nSummary of file downloads:"
    @statuses.each_with_index do |status, idx|
      puts "[#{idx+1}] ID=#{status.id}, Title=\"#{status.title}\", State=#{status.state}, File=#{status.filename}, Error=#{status.error_message}"
    end
  end

  ##
  # Write the statuses to a JSON file in the output folder.
  def write_statuses_to_json
    filename = File.join(@output_folder, "download_status_#{@timestamp}.json")
    data = @statuses.map(&:to_h)
    File.open(filename, 'w') do |f|
      f.write(JSON.pretty_generate(data))
    end
    puts "Status written to #{filename}"
  end
end

if __FILE__ == $0
  # Entry point for running the script from the command line.
  # Downloads all signed documents and writes a status log, even if interrupted.
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