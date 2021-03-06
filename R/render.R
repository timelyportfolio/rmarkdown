
#' @export
render <- function(input,
                   output_format = NULL,
                   output_file = NULL,
                   output_dir = NULL,
                   output_options = NULL,
                   intermediates_dir = NULL,
                   runtime = c("auto", "static", "shiny"),
                   clean = TRUE,
                   envir = parent.frame(),
                   quiet = FALSE,
                   encoding = getOption("encoding")) {

  perf_timer_start("render")

  # check for "all" output formats
  if (identical(output_format, "all")) {
    output_format <- enumerate_output_formats(input, envir, encoding)
    if (is.null(output_format))
      output_format <- "html_document"
  }

  # check for a list of output formats -- if there is more than one
  # then recursively call this function with each format by name
  if (is.character(output_format) && length(output_format) > 1) {
    outputs <- character()
    for (format in output_format) {
      # the output_file argument is intentionally ignored (we can't give
      # the same name to each rendered output); copy the rest by name
      output <- render(input = input,
                       output_format = format,
                       output_file = NULL,
                       output_dir = output_dir,
                       output_options = output_options,
                       intermediates_dir = intermediates_dir,
                       runtime = runtime,
                       clean = clean,
                       envir = envir,
                       quiet = quiet,
                       encoding = encoding)
      outputs <- c(outputs, output)
    }
    return(invisible(outputs))
  }

  # check for required version of pandoc
  required_pandoc <- "1.12.3"
  if (!pandoc_available(required_pandoc)) {
    stop("pandoc version ", required_pandoc, " or higher ",
         "is required and was not found.", call. = FALSE)
  }

  # setup a cleanup function for intermediate files
  intermediates <- c()
  on.exit(lapply(intermediates,
                 function(f) {
                   if (clean && file.exists(f))
                     unlink(f, recursive = TRUE)
                 }),
          add = TRUE)

  # ensure we have a directory to store intermediates
  if (!is.null(intermediates_dir) && !file.exists(intermediates_dir))
    dir.create(intermediates_dir)
  intermediates_loc <- function(file) {
    if (is.null(intermediates_dir))
      file
    else
      file.path(intermediates_dir, file)
  }

  # if the input file has spaces in it's name then make a copy
  # that doesn't have spaces
  if (grepl(' ', basename(input), fixed=TRUE)) {
    input_no_spaces <- intermediates_loc(
        file_name_without_spaces(basename(input)))
    if (file.exists(input_no_spaces)) {
      stop("The name of the input file cannot contain spaces (attempted to ",
           "copy to a version without spaces '", input_no_spaces, "' ",
           "however that file already exists)", call. = FALSE)
    }
    file.copy(input, input_no_spaces, overwrite = TRUE)
    intermediates <- c(intermediates, input_no_spaces)
    input <- input_no_spaces
  }

  # execute within the input file's directory
  oldwd <- setwd(dirname(tools::file_path_as_absolute(input)))
  on.exit(setwd(oldwd), add = TRUE)

  # reset the name of the input file to be relative and calculate variations
  # on the filename for our various intermediate targets
  input <- basename(input)
  knit_input <- input
  knit_output <- intermediates_loc(file_with_meta_ext(input, "knit", "md"))

  intermediates <- c(intermediates, knit_output)
  utf8_input <- intermediates_loc(file_with_meta_ext(input, "utf8", "md"))
  intermediates <- c(intermediates, utf8_input)

  # track whether this was straight markdown input (to prevent keep_md later)
  md_input <- identical(tolower(tools::file_ext(input)), "md")

  # if this is an R script then spin it first
  if (identical(tolower(tools::file_ext(input)), "r")) {
    # make a copy of the file to spin
    spin_input <- intermediates_loc(file_with_meta_ext(input, "spin", "R"))
    file.copy(input, spin_input, overwrite = TRUE)
    intermediates <- c(intermediates, spin_input)
    # spin it
    spin_rmd <- knitr::spin(spin_input,
                            knit = FALSE,
                            envir = envir,
                            format = "Rmd")
    intermediates <- c(intermediates, spin_rmd)
    knit_input <- spin_rmd
    # append default metadata (this will be ignored if there is user
    # metadata elsewhere in the file)
    metadata <- paste('\n',
      '---\n',
      'title: "', input, '"\n',
      'author: "', Sys.info()[["user"]], '"\n',
      'date: "', date(), '"\n',
      '---\n'
    , sep = "")
    if (!identical(encoding, "native.enc"))
      metadata <- iconv(metadata, to = encoding)
    cat(metadata, file = knit_input, append = TRUE)
  }

  # read the input file
  input_lines <- read_lines_utf8(knit_input, encoding)

  # read the yaml front matter
  yaml_front_matter <- parse_yaml_front_matter(input_lines)

  # if we haven't been passed a fully formed output format then
  # resolve it by looking at the yaml
  if (!is_output_format(output_format)) {
    output_format <- output_format_from_yaml_front_matter(input_lines,
                                                          output_options,
                                                          output_format)
    output_format <- create_output_format(output_format$name,
                                          output_format$options)
  }
  pandoc_to <- output_format$pandoc$to

  # determine whether we need to run citeproc (based on whether we
  # have references in the input)
  run_citeproc <- citeproc_required(yaml_front_matter, input_lines)

  # generate outpout file based on input filename
  if (is.null(output_file))
    output_file <- pandoc_output_file(input, output_format$pandoc)

  # if an output_dir was specified then concatenate it with the output file
  if (!is.null(output_dir)) {
    if (!file.exists(output_dir))
      dir.create(output_dir)
    output_file <- file.path(output_dir, basename(output_file))
  }
  output_dir <- dirname(output_file)

  # use output filename based files dir
  files_dir <-file.path(output_dir, knitr_files_dir(basename(output_file)))

  # default to no cache_dir knit_meta (some may be generated by the knit)
  cache_dir <- NULL
  knit_meta <- NULL

  # knit if necessary
  if (tolower(tools::file_ext(input)) %in% c("r", "rmd", "rmarkdown")) {

    # restore options and hooks after knit
    optk <- knitr::opts_knit$get()
    on.exit(knitr::opts_knit$restore(optk), add = TRUE)
    optc <- knitr::opts_chunk$get()
    on.exit(knitr::opts_chunk$restore(optc), add = TRUE)
    hooks <- knitr::knit_hooks$get()
    on.exit(knitr::knit_hooks$restore(hooks), add = TRUE)

    # reset knit_meta (and ensure it's always reset before exiting render)
    knit_meta_reset()
    on.exit(knit_meta_reset(), add = TRUE)

    # default rendering and chunk options
    knitr::render_markdown()
    knitr::opts_chunk$set(tidy = FALSE, error = FALSE)

    # enable knitr hooks to have knowledge of the final output format
    knitr::opts_knit$set(rmarkdown.pandoc.to = pandoc_to)
    knitr::opts_knit$set(rmarkdown.keep_md = output_format$keep_md)
    knitr::opts_knit$set(rmarkdown.version = 2)

    # trim whitespace from around source code
    if (packageVersion("knitr") < "1.5.23") {
      local({
        hook_source = knitr::knit_hooks$get('source')
        knitr::knit_hooks$set(source = function(x, options) {
          hook_source(strip_white(x), options)
        })
      })
    }

    # use filename based figure and cache directories
    figures_dir <- paste(files_dir, "/figure-", pandoc_to, "/", sep = "")
    knitr::opts_chunk$set(fig.path=figures_dir)
    cache_dir <-knitr_cache_dir(input, pandoc_to)
    knitr::opts_chunk$set(cache.path=cache_dir)

    # merge user options and hooks
    if (!is.null(output_format$knitr)) {
      knitr::opts_knit$set(as.list(output_format$knitr$opts_knit))
      knitr::opts_chunk$set(as.list(output_format$knitr$opts_chunk))
      knitr::knit_hooks$set(as.list(output_format$knitr$knit_hooks))
    }

    # presume that we're rendering as a static document unless specified
    # otherwise in the parameters
    runtime <- match.arg(runtime)
    if (identical(runtime, "auto")) {
      if (!is.null(yaml_front_matter$runtime))
        runtime <- yaml_front_matter$runtime
      else
        runtime <- "static"
    }
    knitr::opts_knit$set(rmarkdown.runtime = runtime)

    # make the yaml_front_matter available as 'metadata' within the
    # knit environment (unless it is already defined there in which case
    # we emit a warning)
    if (!exists("metadata", envir = envir)) {
      assign("metadata", yaml_front_matter, envir = envir)
      on.exit(remove("metadata", envir = envir), add = TRUE)
    } else {
      warning("'metadata' object already exists in knit environment ",
              "so won't be accessible during knit", call. = FALSE)
    }

    perf_timer_start("knitr")

    # perform the knit
    input <- knitr::knit(knit_input,
                         knit_output,
                         envir = envir,
                         quiet = quiet,
                         encoding = encoding)

    perf_timer_stop("knitr")

    # pull any R Markdown warnings from knit_meta and emit
    rmd_warnings <- knit_meta_reset(class = "rmd_warning")
    for (rmd_warning in rmd_warnings) {
      message("Warning: ", rmd_warning)
    }

    # collect remaining knit_meta
    knit_meta <- knit_meta_reset()

    # if this isn't html and there are html dependencies then flag an error
    if (!(is_pandoc_to_html(output_format$pandoc) ||
          identical(tolower(tools::file_ext(output_file)), "html")))  {
      if (has_html_dependencies(knit_meta)) {
        stop("Functions that produce HTML output found in document targeting ",
             pandoc_to, " output.\nPlease change the output type ",
             "of this document to HTML.", call. = FALSE)
      }
      if (!identical(runtime, "static")) {
        stop("Runtime '", runtime, "' is not supported for ",
             pandoc_to, " output.\nPlease change the output type ",
             "of this document to HTML.", call. = FALSE)
      }
    }
  }

  # clean the files_dir if we've either been asking to clean supporting files or
  # the knitr cache is active
  if (output_format$clean_supporting && (is.null(cache_dir) || !file.exists(cache_dir)))
      intermediates <- c(intermediates, files_dir)

  # read the input text as UTF-8 then write it back out
  input_text <- read_lines_utf8(input, encoding)
  writeLines(input_text, utf8_input, useBytes = TRUE)

  perf_timer_start("pre-processor")

  # call any pre_processor
  if (!is.null(output_format$pre_processor)) {
    extra_args <- output_format$pre_processor(yaml_front_matter,
                                              utf8_input,
                                              runtime,
                                              knit_meta,
                                              files_dir,
                                              output_dir)
    output_format$pandoc$args <- c(output_format$pandoc$args, extra_args)
  }

  perf_timer_stop("pre-processor")

  # if we are running citeproc then explicitly forward the bibliography
  # on the command line (works around pandoc-citeproc issue whereby yaml
  # strings that begin with numbers are interpreted as numbers)
  if (!is.null(yaml_front_matter$bibliography)) {
    output_format$pandoc$args <- c(output_format$pandoc$args,
      rbind("--bibliography", pandoc_path_arg(yaml_front_matter$bibliography)))
  }

  perf_timer_start("pandoc")

  # run intermediate conversion if it's been specified
  if (output_format$pandoc$keep_tex) {
    pandoc_convert(utf8_input,
                   pandoc_to,
                   output_format$pandoc$from,
                   file_with_ext(output_file, "tex"),
                   run_citeproc,
                   output_format$pandoc$args,
                   !quiet)
  }

  # run the main conversion
  pandoc_convert(utf8_input,
                 pandoc_to,
                 output_format$pandoc$from,
                 output_file,
                 run_citeproc,
                 output_format$pandoc$args,
                 !quiet)

  perf_timer_stop("pandoc")

  perf_timer_start("post-processor")

  # if there is a post-processor then call it
  if (!is.null(output_format$post_processor))
    output_file <- output_format$post_processor(yaml_front_matter,
                                                utf8_input,
                                                output_file,
                                                clean,
                                                !quiet)

  if (!quiet)
    message("\nOutput created: ", output_file)

  perf_timer_stop("post-processor")

  perf_timer_stop("render")

  # write markdown output if requested
  if (output_format$keep_md && !md_input) {

    md <- c(md_header_from_front_matter(yaml_front_matter),
            partition_yaml_front_matter(input_text)$body)

    writeLines(md, file_with_ext(output_file, "md"), useBytes = TRUE)
  }

  # return the full path to the output file
  invisible(tools::file_path_as_absolute(output_file))
}


#' Render supporting files for an input document
#'
#' Render (copy) required supporting files for an input document to the _files
#' directory associated with the document.
#'
#' @param from Directory to copy from
#' @param files_dir Directory to copy files into
#' @param rename_to Optional rename of source directory after it is copied
#'
#' @return The relative path to the supporting files. This path is suitable
#' for inclusion in HTML\code{href} and \code{src} attributes.
#'
#' @export
render_supporting_files <- function(from, files_dir, rename_to = NULL) {

  # auto-create directory for supporting files
  if (!file.exists(files_dir))
    dir.create(files_dir)

  # target directory is based on the dirname of the path or the rename_to
  # value if it was provided
  target_stage_dir <- file.path(files_dir, basename(from))
  target_dir <- file.path(files_dir, ifelse(is.null(rename_to),
                                     basename(from),
                                     rename_to))

  # copy the directory if it hasn't already been copied
  if (!file.exists(target_dir) && !file.exists(target_stage_dir)) {
    file.copy(from = from,
              to = files_dir,
              recursive = TRUE)
    if (!is.null(rename_to)) {
      file.rename(from = target_stage_dir,
                  to = target_dir)
    }
  }

  # return the target dir (used to form links in the HTML)
  target_dir
}

# reset knitr meta output (returns any meta output generated since the last
# call to knit_meta_reset), optionally scoped to a specific output class
knit_meta_reset <- function(class = NULL) {
  if (packageVersion("knitr") >= "1.5.26")
    knitr::knit_meta(class, clean = TRUE)
  else
    NULL
}

md_header_from_front_matter <- function(front_matter) {

  md <- c()

  if (!is.null(front_matter$title))
    md <- c(md, paste("# ", front_matter$title, sep = ""))

  if (is.character(front_matter$author)) {
    authors <- paste(front_matter$author, "  ", sep = "")
    md <- c(md, authors)
  }

  if (!is.null(front_matter$date))
    md <- c(md, paste(front_matter$date, "  ", sep = ""))

  md
}




