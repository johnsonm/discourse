require File.expand_path(File.dirname(__FILE__) + "/base.rb")

require 'csv'

# Updater for Friends+Me Google+ Exporter (F+MG+E) output.
#
# Only updates existing posts and comments to latest formatting and
# all images found, including fixing markup bugs.  Does not import
# any new users or posts, and does not undelete.  Updating new posts
# can be done by re-running the original importer.
#
# Honors a subset of the arguments from friendsmegplus.rb appropriate
# to this function.
#
# Takes the full path (absolute or relative) to
# * each of the F+MG+E JSON export files you want to import
# * the F+MG+E google-plus-image-list.csv file,
#
# You can provide all the F+MG+E JSON export files in a single import
# run.  This will be the fastest way to do the entire import if you
# have enough memory and disk space.  It will work just as well to
# import each F+MG+E JSON export file separately.  This might be
# valuable if you have memory or space limitations, as the memory to
# hold all the data from the F+MG+E JSON export files is one of the
# key resources used by this script.
#
# Provide a filename that ends with "upload-paths.txt" and the names
# of each of the files uploaded will be written to the file with that
# name.  This will include any files that might have been uploaded
# for any modified posts, so any file that is newly uploaded should
# have its name in that file, but not every file name mentioned in the
# upload-paths.txt file will have been newly-uploaded in this pass.
#
# Edit values at the top of the script to fit your preferences

class ImportScripts::FMGP < ImportScripts::Base

  def initialize
    super

    # Set this to the base URL for the site; required for importing videos
    # In production, with S3 configured, seems to be just proto 'https:'
    @site_base_url = 'http://localhost:3000'
    @system_user = Discourse.system_user
    SiteSetting.max_image_size_kb = 40960
    SiteSetting.max_attachment_size_kb = 40960
    # handle the same video extension as the rest of Discourse
    SiteSetting.authorized_extensions = (SiteSetting.authorized_extensions.split("|") + ['mp4', 'mov', 'webm', 'ogv']).uniq.join("|")

    # JSON files produced by F+MG+E as an export of a community
    @feeds = []

    # CSV is map to downloaded images and/or videos (exported separately)
    @images = {}

    # map from Google ID to local system users where necessary
    # {
    #   "128465039243871098234": "handle"
    # }
    # GoogleID 128465039243871098234 will show up as @handle
    @usermap = {}

    # G+ user IDs to filter out (spam, abuse) — no topics or posts, silence and suspend when creating
    # loaded from blacklist.json as array of google ids `[ 92310293874, 12378491235293 ]`
    @blacklist = Set[]
    @imagefiles = nil
    @summaryfile = nil

    # every argument is a filename, do the right thing based on the file name
    ARGV.each do |arg|
      if arg.end_with?('.csv')
        # CSV files produced by F+MG+E have "URL";"IsDownloaded";"FileName";"FilePath";"FileSize"
        CSV.foreach(arg, :headers => true, :col_sep => ';') do |row|
          @images[row[0]] = {
            :filename => row[2],
            :filepath => row[3],
            :filesize => row[4]
          }
        end
      elsif arg.end_with?("upload-paths.txt")
        @imagefiles = File.open(arg, "w")
      elsif arg.end_with?("summary.json")
        @summaryfile = File.open(arg, "w")
      elsif arg.end_with?("usermap.json")
        @usermap = load_fmgp_json(arg)
      elsif arg.end_with?('blacklist.json')
        @blacklist = load_fmgp_json(arg).map{|i| i.to_s}.to_set
      elsif arg.end_with?('.json')
        @feeds << load_fmgp_json(arg)
      else
        raise RuntimeError.new("unknown argument #{arg}")
      end
    end

    # remember google auth DB lookup results
    @emails = {}
    # remember uploaded images
    @uploaded = {}
    # counters for post progress
    @topics_updated = 0
    @posts_updated = 0
    @topics_unchanged = 0
    @posts_unchanged = 0
    @topics_skipped = 0
    @posts_skipped = 0

    # collect users that no longer map
    @invalid_users = Set[]
    # collect images to write out only if post is changed in any way
    @post_images = []

  end

  def execute
    puts "", "Updating imports from Friends+Me Google+ Exporter..."

    load_users
    notify_missing_users
    update_posts

    @imagefiles.close() if !@imagefiles.nil?
    @summaryfile.write({
      :topics_updated => @topics_updated,
      :posts_updated => @posts_updated,
      :total_updated => @topics_updated + @posts_updated,
      :topics_unchanged => @topics_unchanged,
      :posts_unchanged => @posts_unchanged,
      :total_unchanged => @topics_unchanged + @posts_unchanged,
      :topics_skipped => @topics_skipped,
      :posts_skipped => @posts_skipped,
      :total_skipped => @topics_skipped + @posts_skipped
    }.to_json) if !@summaryfile.nil?
    puts ""
    puts "", "Done"
  end

  def load_fmgp_json(filename)
    raise RuntimeError.new("File #{filename} not found") if !File.exists?(filename)
    JSON.parse(File.read(filename))
  end

  def load_users
    puts '', "Mapping Google+ post and comment author users..."

    # collect authors of both posts and comments
    @feeds.each do |feed|
      feed["accounts"].each do |account|
        account["communities"].each do |community|
          community["categories"].each do |category|
            category["posts"].each do |post|
              import_author_user(post["author"])
              if post["message"].present?
                import_message_users(post["message"])
              end
              post["comments"].each do |comment|
                import_author_user(comment["author"])
                if comment["message"].present?
                  import_message_users(comment["message"])
                end
              end
            end
          end
        end
      end
    end
  end

  def import_author_user(author)
    id = author["id"]
    name = author["name"]
    import_google_user(id, name)
  end

  def import_message_users(message)
    message.each do |fragment|
      if fragment[0] == 3 and !fragment[2].nil?
        # deleted G+ users show up with a null ID
        import_google_user(fragment[2], fragment[1])
      end
    end
  end

  def import_google_user(id, name)
    if !@emails[id].present?
      google_user_info = UserAssociatedAccount.find_by(provider_name: 'google_oauth2', provider_uid: id.to_i)
      if google_user_info.nil?
        if !@usermap.include?(id.to_s) and !@blacklist.include?(id.to_s)
          @invalid_users.add([id.to_s, name])
        end
      else
        # user already on system
        u = User.find(google_user_info.user_id)
        email = u.email
        @emails[id] = email
      end
    end
  end

  def notify_missing_users
    if @invalid_users.length > 0
      puts '', 'usermap.json suggestions'
      puts '{'
      @invalid_users.each do |user|
        puts "  \"#{user[0]}\": \"#{user[1]}\","
      end
      puts '}'
    end
  end

  def update_posts
    # "post" is confusing:
    # - A google+ post is a discourse topic
    # - A google+ comment is a discourse post

    puts '', "Updating Google+ posts and comments..."

    @feeds.each do |feed|
      feed["accounts"].each do |account|
        account["communities"].each do |community|
          community["categories"].each do |category|
            category["posts"].each do |post|
              # G+ post / Discourse topic
              import_topic(post, category)
              print("\rUpdated: #{@topics_updated}/#{@posts_updated} topics/posts; unchanged: #{@topics_unchanged}/#{@posts_unchanged}; new skipped: #{@topics_skipped}/#{@posts_skipped})       ")
            end
          end
        end
      end
    end

    puts ''
  end

  def import_topic(post, category)
    # no parent for discourse topics / G+ posts
    if topic_id = post_id_from_imported_post_id(post["id"])
      # Update only if we already have this topic
      p = Post.find_by(id: topic_id)
      if !p.nil? and update_raw(post, p)
        @topics_updated += 1
      else
        @topics_unchanged += 1
      end
    else
      @topics_skipped += 1
    end
    # iterate over comments in post
    post["comments"].each do |comment|
      # category is nil for comments
      if post_id = post_id_from_imported_post_id(comment["id"])
        p = Post.find_by(id: post_id)
        if !p.nil? and update_raw(comment, p)
          @posts_updated += 1
        else
          @posts_unchanged += 1
        end
      else
        @posts_skipped += 1
      end
    end
  end

  def update_raw(post, p)
    return false if !p.deleted_at.nil?
    return false if @usermap.include?(p.user_id) and @usermap[p.user_id].nil?
    raw = formatted_message(post)
    if p.raw.strip != raw.strip
      #puts '', 'OLD', p.raw, ''
      #puts '', 'NEW', raw, ''
      p.raw = raw
      p.baked_version = nil
      p.save
      @imagefiles.write(@post_images.join('')) if !@imagefiles.nil?
      @post_images = []
      return true
    end
    @post_images = []
    return false
  end

  def formatted_message(post)
    lines = []
    urls_seen = Set[]
    if post["message"].present?
      post["message"].each do |fragment|
        lines << formatted_message_fragment(fragment, post, urls_seen)
      end
    end
    # yes, both "image" and "images"; "video" and "videos" :(
    if post["video"].present?
      lines << "\n#{formatted_link(post["video"]["proxy"])}\n"
    elsif post["image"].present?
      # if both image and video, image is a cover image for the video
      lines << "\n#{formatted_link(post["image"]["proxy"])}\n"
    end
    if post["images"].present?
      post["images"].each do |image|
        lines << "\n#{formatted_link(image["proxy"])}\n"
      end
    end
    if post["videos"].present?
      post["videos"].each do |video|
        lines << "\n#{formatted_link(video["proxy"])}\n"
      end
    end
    if post["link"].present? and post["link"]["url"].present?
      url = post["link"]["url"]
      if !urls_seen.include?(url)
        # add the URL only if it wasn't already referenced, because
        # they are often redundant
        lines << "\n#{post["link"]["url"]}\n"
        urls_seen.add(url)
      end
    end
    lines.join("")
  end

  def formatted_message_fragment(fragment, post, urls_seen)
    # markdown does not nest reliably the same as either G+'s markup or what users intended in G+, so generate HTML codes
    # this method uses return to make sure it doesn't fall through accidentally
    if fragment[0] == 0
      # Random zero-width join characters break the output; in particular, they are
      # common after plus-references and break @name recognition. Just get rid of them.
      # Also deal with 0x80 (really‽) and non-breaking spaces
      text = fragment[1].gsub(/(\u200d|\u0080)/,"").gsub(/\u00a0/," ")
      if fragment[2].nil?
        return text
      else
        if fragment[2]["italic"].present?
          text = "<i>#{text}</i>"
        end
        if fragment[2]["bold"].present?
          text = "<b>#{text}</b>"
        end
        if fragment[2]["strikethrough"].present?
          # s more likely than del to represent user intent?
          text = "<s>#{text}</s>"
        end
        return text
      end
    elsif fragment[0] == 1
      return "\n"
    elsif fragment[0] == 2
      urls_seen.add(fragment[2])
      return formatted_link_text(fragment[2], fragment[1])
    elsif fragment[0] == 3
      # reference to a user
      if @usermap.include?(fragment[2].to_s)
        return "@#{@usermap[fragment[2].to_s]}"
      end
      if fragment[2].nil?
        # deleted G+ users show up with a null ID
        return "<b>+#{fragment[1]}</b>"
      end
      # G+ occasionally doesn't put proper spaces after users
      if user = find_user_by_import_id(fragment[2])
        # user was in this import's authors
        return "@#{user.username} "
      else
        if google_user_info = UserAssociatedAccount.find_by(provider_name: 'google_oauth2', provider_uid: fragment[2])
          # user was not in this import, but has logged in or been imported otherwise
          user = User.find(google_user_info.user_id)
          return "@#{user.username} "
        else
          # if you want to fall back to their G+ name, just erase the raise above,
          # but this should not happen
          return "<b>+#{fragment[1]}</b>"
        end
      end
    elsif fragment[0] == 4
      # hashtag, the octothorpe is included
      return fragment[1]
    else
      raise RuntimeError.new("message code #{fragment[0]} not recognized!")
    end
  end

  def formatted_link(url)
    formatted_link_text(url, url)
  end

  def embedded_image_md(upload)
    # remove unnecessary size logic relative to embedded_image_html
    upload_name = upload.short_url || upload.url
    if upload_name =~ /\.(mov|mp4|webm|ogv)$/i
      @site_base_url + upload.url
    else
      "![#{upload.original_filename}](#{upload_name})"
    end
  end

  def formatted_link_text(url, text)
    # two ways to present images attached to posts; you may want to edit this for preference
    # - display: embedded_image_html(upload)
    # - download links: attachment_html(upload, text)
    # you might even want to make it depend on the file name.
    if @images[text].present?
      # F+MG+E provides the URL it downloaded in the text slot
      # we won't use the plus url at all since it will disappear anyway
      url = text
    end
    if @uploaded[url].present?
      upload = @uploaded[url]
      return "\n#{embedded_image_md(upload)}"
    elsif @images[url].present?
      missing = "<i>missing/deleted image from Google+</i>"
      return missing if !Pathname.new(@images[url][:filepath]).exist?
      @post_images << "#{@images[url][:filepath]}\n"
      upload = create_upload(@system_user.id, @images[url][:filepath], @images[url][:filename])
      if upload.nil? or upload.id.nil?
        # upload can be nil if the image conversion fails
        # upload.id can be nil for at least videos, and possibly deleted images
        return missing
      end
      upload.save
      @uploaded[url] = upload
      return "\n#{embedded_image_md(upload)}"
    end
    if text == url
      # leave the URL bare and Discourse will do the right thing
      return url
    else
      # It turns out that the only place we get here, google has done its own text
      # interpolation that doesn't look good on Discourse, so while it looks like
      # this should be:
      # return "[#{text}](#{url})"
      # it actually looks better to throw away the google-provided text:
      return url
    end
  end
end

if __FILE__ == $0
  ImportScripts::FMGP.new.perform
end
