#' Fetch an R object from an S3 path.
#'
#' @param path character. A full S3 path.
#' @param bucket_location character. Usually \code{"US"}.
#' @param verbose logical. If \code{TRUE}, the \code{s3cmd}
#'    utility verbose flag will be set.
#' @param debug logical. If \code{TRUE}, the \code{s3cmd}
#'    utility debug flag will be set.
#' @param cache logical. If \code{TRUE}, an LRU in-memory cache will be referenced.
#' @param storage_format character. What format the object is stored in. Defaults to RDS.
#' @aliases s3.put
#' @return For \code{s3.get}, the R object stored in RDS format on S3 in the \code{path}.
#'    For \code{s3.put}, the system exit code from running the \code{s3cmd}
#'    command line tool to perform the upload.
s3.get <- function (path, bucket_location = "US", verbose = FALSE, debug = FALSE, cache = TRUE, storage_format = c("RDS", "CSV", "table"), ...) {
  storage_format <- match.arg(storage_format)

  ## This inappropriately-named function actually checks existence
  ## of a *path*, not a bucket.
  AWS.tools:::check.bucket(path)

  # Helper function for fetching data from s3
  fetch <- function(path, storage_format, bucket_location, ...) {
    x.serialized <- tempfile()
    dir.create(dirname(x.serialized), showWarnings = FALSE, recursive = TRUE)
    ## We remove the file [when we exit the function](https://stat.ethz.ch/R-manual/R-patched/library/base/html/on.exit.html).
    on.exit(unlink(x.serialized), add = TRUE)

    if (file.exists(x.serialized)) {
      unlink(x.serialized, force = TRUE)
    }

    ## Run the s3cmd tool to fetch the file from S3.
    cmd <- s3cmd_get_command(path, x.serialized, bucket_location_to_flag(bucket_location), verbose, debug)
    status <- system2(s3cmd(), cmd)

    if (as.logical(status)) {
      warning("Nothing exists for key ", path)
      `attr<-`(`class<-`(data.frame(), c("s3mpi_error", status)), "key", path)
    } else {
      ## And then read it back in RDS format.
      load_from_file <- get(paste0("load_as_", storage_format))
      load_from_file(x.serialized, ...)
    }
  }

  ## Check for the path in the cache
  ## If it does not exist, create and return its entry.
  ## The `s3LRUcache` helper is defined in utils.R
  if (is.windows() || isTRUE(get_option("s3mpi.disable_lru_cache")) || !isTRUE(cache)) {
    ## We do not have awk, which we will need for the moment to
    ## extract the modified time of the S3 object.
    ans <- fetch(path, storage_format, bucket_location, ...)
  } else if (!s3LRUcache()$exists(path)) {
    ans <- fetch(path, storage_format, bucket_location, ...)
    ## We store the value of the R object in a *least recently used cache*,
    ## expecting the user to not think about optimizing their code and
    ## call `s3read` with the same key multiple times in one session. With
    ## this approach, we keep the latest 10 object in RAM and do not have
    ## to reload them into memory unnecessarily--a wise time-space trade-off!
    tryCatch(s3LRUcache()$set(path, ans), error = function(...) {
      warning("Failed to store object in LRU cache. Repeated calls to ",
              "s3read will not benefit from a performance speedup.")
    })
  } else {
    # Check time on s3LRUcache's copy
    last_cached <- s3LRUcache()$last_accessed(path) # assumes a POSIXct object

    # Check time on s3 remote's copy using the `s3cmd info` command.
    s3.cmd <- paste("info ", path, "| head -n 3 | tail -n 1")
    result <- system2(s3cmd(), s3.cmd, stdout = TRUE, stderr = NULL)
    # The `s3cmd info` command produces the output
    # "    Last mod:  Tue, 16 Jun 2015 19:36:10 GMT"
    # in its third line, so we subset to the 20-39 index range
    # to extract "16 Jun 2015 19:36:10".
    result <- substring(result, 20, 39)
    last_updated <- strptime(result, format = "%d %b %Y %H:%M:%S", tz = "GMT")

    if (last_updated > last_cached) {
      ans <- fetch(path, storage_format, bucket_location, ...)
      s3LRUcache()$set(path, ans)
    } else {
      ans <- s3LRUcache()$get(path)
    }
  }
  ans
}

s3cmd_get_command <- function(path, file, bucket_flag, verbose, debug) {
  if (use_legacy_api()) {
    paste("get", paste0('"', path, '"'), file,
          bucket_flag,
          if (verbose) "--verbose --progress" else "--no-progress",
          if (debug) "--debug" else "")
  } else {
    paste0("s3 cp ", path, " ", file)
  }
}

## Given an s3cmd path and a bucket location, will construct a flag
## argument for s3cmd.  If it looks like the s3cmd is actually
## pointing to an s4cmd, return empty string as s4cmd doesn't
## support bucket location.
bucket_location_to_flag <- function(bucket_location) {
  if (grepl("s4cmd", s3cmd())) {
    if (bucket_location != "US") {
        warning(paste0("Ignoring non-default bucket location ('",
                       bucket_location,
                       "') in s3mpi::s3.get since s4cmd was detected",
                       "-- this might be a little slower but is safe to ignore."));
    }
    return("")
  }
  return(paste("--bucket_location", bucket_location))
}

load_as_RDS <- function(filename, ...) {
  readRDS(filename, ...)
}

load_as_CSV <- function(filename, ...) {
  read.csv(filename, ..., stringsAsFactors = FALSE)
}

load_as_table <- function(filename, ...) {
  read.table(filename, ..., stringsAsFactors = FALSE)
}

#' Printing for s3mpi errors.
#'
#' @param x ANY. R object to print.
#' @param ... additional objects to pass to print function.
#' @export
print.s3mpi_error <- function(x, ...)  {
  cat("Error reading from S3: key", crayon::white$bold(attr(x, "key")), "not found.\n")
}
