# encoding: utf-8

module Slideshow

## fix:/todo: move generation code out of command into its own class
##   not residing/depending on cli

class Gen     ## todo: rename command to build

  include LogUtils::Logging

  include ManifestHelper

### fix: remove opts, use config (wrapped!!)

  def initialize( opts, config, headers )
    @opts    = opts
    @config  = config
    @headers = headers
    
    ## todo: check if we need to use expand_path - Dir.pwd always absolute (check ~/user etc.)
    @usrdir = File.expand_path( Dir.pwd )  # save original (current) working directory 
  end

  attr_reader :usrdir   # original working dir (user called slideshow from)
  attr_reader :srcdir, :outdir, :pakdir    # NB: "initalized" in create_slideshow


  attr_reader :opts, :config, :headers
  attr_reader :session      # give helpers/plugins a session-like hash

 
  def guard_text( text )
    # todo/fix 2: note we need to differentiate between blocks and inline
    #   thus, to avoid runs - use guard_block (add a leading newline to avoid getting include in block that goes before)
    
    # todo/fix: remove wrap_markup; replace w/ guard_text
    #   why: text might be css, js, not just html
    
    ###  !!!!!!!!!!!!
    ## todo: add print depreciation warning
    
    wrap_markup( text )
  end

  def guard_block( text )   ## use/rename to guard_text_block - why? why not?
    # wrap in newlines to avoid runons
    "\n\n#{text}\n\n"
  end
  
  def guard_inline( text )   ## use/rename to guard_text_inline - why? why not?
    wrap_markup( text )
  end
   
  def wrap_markup( text )
    # saveguard with wrapper etc./no further processing needed - check how to do in markdown
    text
  end


  # move into a filter??
  def post_processing_slides( content )
    
    # 1) add slide breaks
  
    if config.slide?  # only allow !SLIDE directives fo slide breaks?
       # do nothing (no extra automagic slide breaks wanted)
    else  
      if config.header_level == 2
        content = add_slide_directive_before_h2( content )
      else # assume level 1
        content = add_slide_directive_before_h1( content )
      end
    end


    dump_content_to_file_debug_html( content )

    # 2) use generic slide break processing instruction to
    #   split content into slides

    slide_counter = 0

    slides       = []
    slide_buf = ""
     
    content.each_line do |line|
       if line.include?( '<!-- _S9SLIDE_' )
          if slide_counter > 0   # found start of new slide (and, thus, end of last slide)
            slides   << slide_buf  # add slide to slide stack
            slide_buf = ""         # reset slide source buffer
          else  # slide_counter == 0
            # check for first slide with missing leading SLIDE directive (possible/allowed in takahashi, for example)
            ##  remove html comments and whitspaces (still any content?)
            ### more than just whitespace? assume its  a slide
            if slide_buf.gsub(/<!--.*?-->/m, '').gsub( /[\n\r\t ]/, '').length > 0
              logger.debug "add slide with missing leading slide directive >#{slide_buf}< with slide_counter == 0"
              slides    << slide_buf
              slide_buf = ""
            else
              logger.debug "skipping slide_buf >#{slide_buf}< with slide_counter == 0"
            end
          end
          slide_counter += 1
       end
       slide_buf  << line
    end
  
    if slide_counter > 0
      slides   << slide_buf     # add slide to slide stack
      slide_buf = ""            # reset slide source buffer 
    end


    slides2 = []
    slides.each do |source|
      slides2 << Slide.new( source, config )
    end


    puts "#{slides2.size} slides found:"
    
    slides2.each_with_index do |slide,i|
      print "  [#{i+1}] "
      if slide.header.present?
        print slide.header
      else
        # remove html comments
        print "-- no header -- | #{slide.content.gsub(/<!--.*?-->/m, '').gsub(/\n/,'$')[0..40]}"
      end
      puts
    end
   
   
    # make content2 and slide2 available to erb template
    # -- todo: cleanup variable names and use attr_readers for content and slide

    ### fix: use class SlideDeck or Deck?? for slides array?
    
    content2 = ""
    slides2.each do |slide|
      content2 << slide.to_classic_html
    end
  
    @content  = content2
    @slides   = slides2     # strutured content
  end


  def create_slideshow( fn )

    manifest_path_or_name = opts.manifest
    
    # add .txt file extension if missing (for convenience)
    if manifest_path_or_name.downcase.ends_with?( '.txt' ) == false
      manifest_path_or_name << '.txt'
    end
  
    logger.debug "manifest=#{manifest_path_or_name}"
    
    # check if file exists (if yes use custom template package!) - allows you to override builtin package with same name 
    if File.exists?( manifest_path_or_name )
      manifestsrc = manifest_path_or_name
    else
      # check for builtin manifests
      manifests = installed_template_manifests
      matches = manifests.select { |m| m[0] == manifest_path_or_name } 

      if matches.empty?
        puts "*** error: unknown template manifest '#{manifest_path_or_name}'"
        # todo: list installed manifests
        exit 2
      end
        
      manifestsrc = matches[0][1]
    end

    ### todo: use File.expand_path( xx, relative_to ) always with second arg
    ##   do NOT default to cwd (because cwd will change!)
    
    # Reference src with absolute path, because this can be used with different pwd
    manifestsrc = File.expand_path( manifestsrc, usrdir )

    # expand output path in current dir and make sure output path exists
    @outdir = File.expand_path( opts.output_path, usrdir )
    logger.debug "setting outdir to >#{outdir}<"
    FileUtils.makedirs( outdir ) unless File.directory? outdir

    dirname  = File.dirname( fn )
    basename = File.basename( fn, '.*' )
    extname  = File.extname( fn )
    logger.debug "dirname=#{dirname}, basename=#{basename}, extname=#{extname}"

    # change working dir to sourcefile dir
    # todo: add a -c option to commandline? to let you set cwd?

    @srcdir = File.expand_path( dirname, usrdir )
    logger.debug "setting srcdir to >#{srcdir}<"

    unless usrdir == srcdir
      logger.debug "changing cwd to src - new >#{srcdir}<, old >#{Dir.pwd}<"
      Dir.chdir srcdir
    end

    puts "Preparing slideshow '#{basename}'..."
     
  # shared variables for templates (binding)
  @content_for = {}  # reset content_for hash

  @name        = basename
  @extname     = extname

  @session     = {}  # reset session hash for plugins/helpers

  inname  =  "#{basename}#{extname}"

  logger.debug "inname=#{inname}"
    
  content = File.read( inname )

  # run text filters
  
  config.text_filters.each do |filter|
    mn = filter.tr( '-', '_' ).to_sym  # construct method name (mn)
    content = send( mn, content )   # call filter e.g.  include_helper_hack( content )  
  end


  if config.takahashi?
    content = takahashi_slide_breaks( content )
  end


  # convert light-weight markup to hypertext

  content = markdown_to_html( content )


  # post-processing

  # make content2 and slide2 available to erb template
    # -- todo: cleanup variable names and use attr_readers for content and slide
  
  # sets @content (all-in-one string) and @slides (structured content; split into slides)
  post_processing_slides( content )


  #### pak merge
  #  nb: change cwd to template pak root

  @pakdir = File.dirname( manifestsrc )  # template pak root - make availabe too in erb via binding
  logger.debug " setting pakdir to >#{pakdir}<"

  #  todo/fix: change current work dir (cwd) in pakman gem itself
  #   for now lets do it here

  logger.debug "changing cwd to pak - new >#{pakdir}<, old >#{Dir.pwd}<"
  Dir.chdir( pakdir )


  pakpath     = outdir

  logger.debug( "manifestsrc >#{manifestsrc}<, pakpath >#{pakpath}<" )

  ###########################################
  ## fix: !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ## todo: setup hash for binding
  ctx = { 'name'    => @name,
          'headers' => @headers, 
          'content' => @content,
          'slides'  => @slides,       # strutured content - use LiquidDrop - why? why not?
          ## add content_for hash
          ## and some more -- ??
        }     

  Pakman::LiquidTemplater.new.merge_pak( manifestsrc, pakpath, ctx, basename )

  logger.debug "restoring cwd to src - new >#{srcdir}<, old >#{Dir.pwd}<"
  Dir.chdir( srcdir )

  ## pop/restore org (original) working folder/dir
  unless usrdir == srcdir
    logger.debug "restoring cwd to usr - new >#{usrdir}<, old >#{Dir.pwd}<"
    Dir.chdir( usrdir )
  end

  puts "Done."
end # method create_slideshow


end # class Gen

end # class Slideshow