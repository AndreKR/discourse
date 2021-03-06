# Post processing that we can do after a post has already been cooked. For
# example, inserting the onebox content, or image sizes.

require_dependency 'oneboxer'

class CookedPostProcessor
  include ActionView::Helpers::NumberHelper

  def initialize(post, opts={})
    @dirty = false
    @opts = opts
    @post = post
    @doc = Nokogiri::HTML::fragment(post.cooked)
    @size_cache = {}
    @has_been_uploaded_cache = {}
  end

  def post_process
    return unless @doc.present?
    post_process_images
    post_process_oneboxes
  end

  def post_process_images
    images = @doc.css("img") - @doc.css(".onebox-result img")
    return unless images.present?

    images.each do |img|
      # keep track of the original src
      src = img['src']
      # make sure the src is absolute (when working with locally uploaded files)
      img['src'] = Discourse.base_url_no_prefix + img['src'] if img['src'] =~ /^\/[^\/]/

      if src.present?
        # make sure the img has both width and height attributes
        update_dimensions!(img)
        # retrieve the associated upload, if any
        upload = get_upload_from_url(img['src'])
        if upload.present?
          # update reverse index
          associate_to_post upload
          # create a thumbnail
          upload.create_thumbnail!
          # optimize image
          img['src'] = optimize_image(img)
          # lightbox treatment
          convert_to_link!(img, upload)
        else
          convert_to_link!(img)
        end
        # mark the post as dirty whenever the src has changed
        @dirty |= src != img['src']
      end
    end

    # Extract the first image from the first post and use it as the 'topic image'
    if @post.post_number == 1
      img = images.first
      @post.topic.update_column :image_url, img['src'] if img['src'].present?
    end

  end

  def post_process_oneboxes
    args = { post_id: @post.id }
    args[:invalidate_oneboxes] = true if @opts[:invalidate_oneboxes]
    # bake onebox content into the post
    result = Oneboxer.apply(@doc) do |url, element|
      Oneboxer.onebox(url, args)
    end
    # mark the post as dirty whenever a onebox as been baked
    @dirty |= result.changed?
  end

  def update_dimensions!(img)
    return if img['width'].present? && img['height'].present?

    w, h = get_size_from_image_sizes(img['src'], @opts[:image_sizes]) || image_dimensions(img['src'])

    if w && h
      img['width'] = w.to_s
      img['height'] = h.to_s
      @dirty = true
    end
  end

  def get_upload_from_url(url)
    if Upload.has_been_uploaded?(url)
      if m = LocalStore.uploaded_regex.match(url)
        Upload.where(id: m[:upload_id]).first
      elsif Upload.is_on_s3?(url)
        Upload.where(url: url).first
      end
    end
  end

  def associate_to_post(upload)
    return if PostUpload.where(post_id: @post.id, upload_id: upload.id).count > 0
    PostUpload.create({ post_id: @post.id, upload_id: upload.id })
  rescue ActiveRecord::RecordNotUnique
    # do not care if it's already associated
  end

  def optimize_image(img)
    return img["src"]
    # 1) optimize using image_optim
    # 2) .png vs. .jpg
  end

  def convert_to_link!(img, upload=nil)
    src = img["src"]
    width, height = img["width"].to_i, img["height"].to_i

    return unless src.present? && width > SiteSetting.auto_link_images_wider_than

    original_width, original_height = get_size(src)

    return unless original_width.to_i > width && original_height.to_i > height

    parent = img.parent
    while parent
      return if parent.name == "a"
      break unless parent.respond_to? :parent
      parent = parent.parent
    end

    # not a hyperlink so we can apply
    img['src'] = upload.thumbnail_url if (upload && upload.thumbnail_url.present?)
    # first, create a div to hold our lightbox
    lightbox = Nokogiri::XML::Node.new "div", @doc
    img.add_next_sibling lightbox
    lightbox.add_child img
    # then, the link to our larger image
    a = Nokogiri::XML::Node.new "a", @doc
    img.add_next_sibling(a)
    a["href"] = src
    a["class"] = "lightbox"
    a.add_child(img)
    # then, some overlay informations
    meta = Nokogiri::XML::Node.new "div", @doc
    meta["class"] = "meta"
    img.add_next_sibling meta

    filename = upload ? upload.original_filename : File.basename(src)
    informations = "#{original_width}x#{original_height}"
    informations << " | #{number_to_human_size(upload.filesize)}" if upload

    meta.add_child create_span_node("filename", filename)
    meta.add_child create_span_node("informations", informations)
    meta.add_child create_span_node("expand")
    # TODO: download
    # TODO: views-count

    @dirty = true
  end

  def create_span_node(klass, content=nil)
    span = Nokogiri::XML::Node.new "span", @doc
    span.content = content if content
    span['class'] = klass
    span
  end

  def get_size_from_image_sizes(src, image_sizes)
    if image_sizes.present?
      if dim = image_sizes[src]
        ImageSizer.resize(dim['width'], dim['height'])
      end
    end
  end

  # Retrieve the image dimensions for a url
  def image_dimensions(url)
    w, h = get_size(url)
    ImageSizer.resize(w, h) if w && h
  end

  def get_size(url)
    # make sure s3 urls have a scheme (otherwise, FastImage will fail)
    url = "http:" + url if Upload.is_on_s3? (url)
    return unless is_valid_image_uri? url
    # we can *always* crawl our own images
    return unless SiteSetting.crawl_images? || Upload.has_been_uploaded?(url)
    @size_cache[url] ||= FastImage.size(url)
  rescue Zlib::BufError # FastImage.size raises BufError for some gifs
  end

  def is_valid_image_uri?(url)
    uri = URI.parse(url)
    %w(http https).include? uri.scheme
  rescue URI::InvalidURIError
  end

  def dirty?
    @dirty
  end

  def html
    @doc.try(:to_html)
  end

end
