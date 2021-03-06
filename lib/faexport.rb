# faexport.rb - Simple data export and feeds from FA
#
# Copyright (C) 2015 Erra Boothale <erra@boothale.net>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   * Neither the name of FAExport nor the names of its contributors may be
#     used to endorse or promote products derived from this software without
#     specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

$:<< File.dirname(__FILE__)

require 'active_support'
require 'active_support/core_ext'
require 'builder'
require 'faexport/scraper'
require 'rdiscount'
require 'sinatra/base'
require 'sinatra/json'
require 'yaml'

module FAExport
  class << self
    attr_accessor :config
  end

  class Application < Sinatra::Base
    set :public_folder, File.join(File.dirname(__FILE__), 'faexport', 'public')
    set :views, File.join(File.dirname(__FILE__), 'faexport', 'views')

    USER_REGEX = /((?:[a-zA-Z0-9\-_~.]|%5B|%5D|%60)+)/
    ID_REGEX = /([0-9]+)/
    COOKIE_REGEX = /^b=[a-z0-9\-]+; a=[a-z0-9\-]+$/

    def initialize(app, config = {})
      FAExport.config = config.with_indifferent_access
      FAExport.config[:cache_time] ||= 30 # seconds
      FAExport.config[:redis_url] ||= ENV['REDISTOGO_URL']
      FAExport.config[:username] ||= ENV['FA_USERNAME']
      FAExport.config[:password] ||= ENV['FA_PASSWORD']
      FAExport.config[:cookie] ||= ENV['FA_COOKIE']
      FAExport.config[:rss_limit] ||= 10
      FAExport.config[:content_types] ||= {
        'json' => 'application/json',
        'xml' => 'application/xml',
        'rss' => 'application/rss+xml'
      }

      @cache = RedisCache.new(FAExport.config[:redis_url],
                              FAExport.config[:cache_time])
      @fa = Furaffinity.new(@cache)

      @system_cookie = FAExport.config[:cookie] || @cache.redis.get('login_cookie') 
      unless @system_cookie
        @system_cookie = @fa.login(FAExport.config[:username], FAExport.config[:password])
        @cache.redis.set('login_cookie', @system_cookie)
      end

      super(app)
    end

    helpers do
      def cache(key)
        @cache.add(key) { yield }
      end

      def set_content_type(type)
        content_type FAExport.config[:content_types][type], 'charset' => 'utf-8'
      end

      def ensure_login!
        unless @user_cookie
          raise FALoginCookieError,
            "You must provide a valid login cookie in the header 'FA_COOKIE'"
        end
      end
    end

    before do
      @user_cookie = request.env['HTTP_FA_COOKIE']
      if @user_cookie
        if @user_cookie =~ COOKIE_REGEX
          @fa.login_cookie = @user_cookie.strip
        else
          raise FALoginCookieError,
            "The login cookie provided must be in the format "\
            "'b=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx; a=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
        end
      else
        @fa.login_cookie = @system_cookie
      end
    end

    after do
      @fa.login_cookie = nil
    end

    get '/' do
      @base_url = request.base_url
      haml :index, layout: :page
    end

    get '/docs' do
      haml :page do
        markdown :docs
      end
    end

    # GET /user/{name}.json
    # GET /user/{name}.xml
    get %r{/user/#{USER_REGEX}\.(json|xml)} do |name, type|
      set_content_type(type)
      cache("data:#{name}.#{type}") do
        case type
        when 'json'
          JSON.pretty_generate @fa.user(name)
        when 'xml'
          @fa.user(name).to_xml(root: 'user', skip_types: true)
        end
      end
    end

    # GET /user/{name}/shouts.rss
    # GET /user/{name}/shouts.json
    # GET /user/{name}/shouts.xml
    get %r{/user/#{USER_REGEX}/shouts\.(rss|json|xml)} do |name, type|
      set_content_type(type)
      cache("shouts:#{name}.#{type}") do
        case type
        when 'rss'
          @name = name.capitalize
          @resource = 'shouts'
          @link = "http://www.furaffinity.net/user/#{name}"
          @posts = @fa.shouts(name).map do |shout|
            @post = {
              title: "Shout from #{shout[:name]}",
              link: "http://www.furaffinity.net/user/#{name}/##{shout[:id]}",
              posted: shout[:posted]
            }
            @description = shout[:text]
            builder :post
          end
          builder :feed
        when 'json'
          JSON.pretty_generate @fa.shouts(name)
        when 'xml'
          @fa.shouts(name).to_xml(root: 'shouts', skip_types: true)
        end
      end
    end

    # GET /user/{name}/watching.json
    # GET /user/{name}/watching.xml
    # GET /user/{name}/watchers.json
    # GET /user/{name}/watchers.xml
    get %r{/user/#{USER_REGEX}/(watching|watchers)\.(json|xml)} do |name, mode, type|
      set_content_type(type)
      page = params[:page] =~ /^[0-9]+$/ ? params[:page] : 1
      is_watchers = mode == 'watchers'
      cache("watching:#{name}.#{type}.#{mode}.#{page}") do
        case type
        when 'json'
          JSON.pretty_generate @fa.budlist(name, page, is_watchers)
        when 'xml'
          @fa.budlist(name, page, is_watchers).to_xml(root: 'users', skip_types: true)
        end
      end
    end

    # GET /user/{name}/commissions.json
    # GET /user/{name}/commissions.xml
    get %r{/user/#{USER_REGEX}/commissions\.(json|xml)} do |name, type|
      set_content_type(type)
      cache("commissions:#{name}.#{type}") do
        case type
        when 'json'
          JSON.pretty_generate @fa.commissions(name)
        when 'xml'
          @fa.commissions(name).to_xml(root: 'commissions', skip_types: true)
        end
      end
    end

    # GET /user/{name}/journals.rss
    # GET /user/{name}/journals.json
    # GET /user/{name}/journals.xml
    get %r{/user/#{USER_REGEX}/journals\.(rss|json|xml)} do |name, type|
      set_content_type(type)
      full = !!params[:full]
      cache("journals:#{name}.#{type}.#{full}") do
        case type
        when 'rss'
          @name = name.capitalize
          @resource = 'journals'
          @link = "http://www.furaffinity.net/journals/#{name}/"
          @posts = @fa.journals(name).take(FAExport.config[:rss_limit]).map do |journal|
            cache "journal:#{journal[:id]}.rss" do
              @post = @fa.journal(journal[:id])
              @description = "<p>#{@post[:description]}</p>"
              builder :post
            end
          end
          builder :feed
        when 'json'
          journals = @fa.journals(name)
          journals = journals.map{|j| j[:id]} unless full
          JSON.pretty_generate journals
        when 'xml'
          journals = @fa.journals(name)
          journals = journals.map{|j| j[:id]} unless full
          journals.to_xml(root: 'journals', skip_types: true)
        end
      end
    end

    # GET /user/{name}/gallery.rss
    # GET /user/{name}/gallery.json
    # GET /user/{name}/gallery.xml
    # GET /user/{name}/scraps.rss
    # GET /user/{name}/scraps.json
    # GET /user/{name}/scraps.xml
    # GET /user/{name}/favorites.rss
    # GET /user/{name}/favorites.json
    # GET /user/{name}/favorites.xml
    get %r{/user/#{USER_REGEX}/(gallery|scraps|favorites)\.(rss|json|xml)} do |name, folder, type|
      set_content_type(type)
      page = params[:page] =~ /^[0-9]+$/ ? params[:page] : 1
      full = !!params[:full]
      include_deleted = !!params[:include_deleted]
      cache("#{folder}:#{name}.#{type}.#{page}.#{full}.#{include_deleted}") do
        case type
        when 'rss'
          @name = name.capitalize
          @resource = folder.capitalize
          @link = "http://www.furaffinity.net/#{folder}/#{name}/"
          subs = @fa.submissions(name, folder, 1)
          subs = subs.reject{|sub| sub[:id].blank?} unless include_deleted
          @posts = subs.take(FAExport.config[:rss_limit]).map do |sub|
            cache "submission:#{sub[:id]}.rss" do
              @post = @fa.submission(sub[:id])
              @description = "<a href=\"#{@post[:link]}\"><img src=\"#{@post[:thumbnail]}"\
                             "\"/></a><br/><br/><p>#{@post[:description]}</p>"
              builder :post
            end
          end
          builder :feed
        when 'json'
          subs =  @fa.submissions(name, folder, page)
          subs = subs.reject{|sub| sub[:id].blank?} unless include_deleted
          subs = subs.map{|sub| sub[:id]} unless full
          JSON.pretty_generate subs
        when 'xml'
          subs =  @fa.submissions(name, folder, page)
          subs = subs.reject{|sub| sub[:id].blank?} unless include_deleted
          subs = subs.map{|sub| sub[:id]} unless full
          subs.to_xml(root: 'submissions', skip_types: true)
        end
      end
    end

    # GET /submission/{id}.json
    # GET /submission/{id}.xml
    get %r{/submission/#{ID_REGEX}\.(json|xml)} do |id, type|
      set_content_type(type)
      cache("submission:#{id}.#{type}") do
        case type
        when 'json'
          JSON.pretty_generate @fa.submission(id)
        when 'xml'
          @fa.submission(id).to_xml(root: 'submission', skip_types: true)
        end
      end
    end

    # GET /journal/{id}.json
    # GET /journal/{id}.xml
    get %r{/journal/#{ID_REGEX}\.(json|xml)} do |id, type|
      set_content_type(type)
      cache("journal:#{id}.#{type}") do
        case type
        when 'json'
          JSON.pretty_generate @fa.journal(id)
        when 'xml'
          @fa.journal(id).to_xml(root: 'journal', skip_types: true)
        end
      end
    end

    # GET /submission/{id}/comments.json
    # GET /submission/{id}/comments.xml
    get %r{/submission/#{ID_REGEX}/comments\.(json|xml)} do |id, type|
      set_content_type(type)
      include_hidden = !!params[:include_hidden]
      cache("submissions_comments:#{id}.#{type}.#{include_hidden}") do
        case type
        when 'json'
          JSON.pretty_generate @fa.submission_comments(id, include_hidden)
        when 'xml'
          @fa.submission_comments(id, include_hidden).to_xml(root: 'comments', skip_types: true)
        end
      end
    end

    # GET /journal/{id}/comments.json
    # GET /journal/{id}/comments.xml
    get %r{/journal/#{ID_REGEX}/comments\.(json|xml)} do |id, type|
      set_content_type(type)
      include_hidden = !!params[:include_hidden]
      cache("journal_comments:#{id}.#{type}.#{include_hidden}") do
        case type
        when 'json'
          JSON.pretty_generate @fa.journal_comments(id, include_hidden)
        when 'xml'
          @fa.journal_comments(id, include_hidden).to_xml(root: 'comments', skip_types: true)
        end
      end
    end

    # GET /search.json?q={query}
    # GET /search.xml?q={query}
    # TODO: Implement RSS
    get %r{/search\.(json|xml)} do |type|
      set_content_type(type)
      full = !!params[:full]
      cache("search_results:#{params.to_s}.#{type}") do
        case type
        when 'json'
          results = @fa.search(params)
          results = results.map{|result| result[:id]} unless full
          JSON.pretty_generate results
        when 'xml'
          results = @fa.search(params)
          results = results.map{|result| result[:id]} unless full
          results.to_xml(root: 'results', skip_types: true)
        end
      end
    end

    post %r{/journal(\.json|)} do |type|
      ensure_login!
      journal = case type
                when '.json' then JSON.parse(request.body.read)
                else params
                end
      result = @fa.submit_journal(journal['title'], journal['description'])

      set_content_type('json')
      JSON.pretty_generate(result)
    end

    error FAError do
      err = env['sinatra.error']
      status case err
      when FASearchError      then 400
      when FALoginCookieError then 400
      when FALoginError       then @user_cookie ? 401 : 503
      when FASystemError      then 404
      when FAStatusError      then 502
      else 500
      end

      JSON.pretty_generate error: err.message, url: err.url
    end

    error do
      status 500
      'FAExport encounter an internal error'
    end
  end
end
