#' Query New Relic Application Metricdata.
#'
#' This function is a facade on the New Relic public REST API for getting application
#' metric data.  You can use it to get any value of any metric over a
#' given time range.  The results are always returned as a time series of
#' numeric values.
#'
#' This executes HTTP queries using the underlying Metric Data REST API at api.newrelic.com.
#' Depending on the duration and period the data may be fetched in successive batches
#' due to the limitations on the amount of data that can be retrieved.
#'
#' @param account_id your New Relic account ID
#' @param api_key your New Relic APM REST API key
#' @param app_id the application id. Use a value of -1 to generate a fake response for tests.
#' @param duration length of time in seconds of the time window of the metric data
#' @param end_time the end of the time window
#' @param period duration of each timeslice as lubridate::Duration or scalar value in seconds, minimum of 60
#' @param metrics a character vector of metric names
#' @param verbose show extra information about the calls
#' @param values a character vector of metric values (calls_per_minute, average_response_time, etc)
#' @param cache TRUE if the query results should be cached to local disk and reused
#'     when subsequent calls have matching parameters
#' @param host use to proxy requests through an intermediate host you can override the default host
#'     of \code{api.newrelic.com}.
#' @param progress_callback is a caller supplied function that takes two arguments: the iteration
#'     number and the total number of iterations.
#' @param ... arguments passed on to \code{progress_callback} if provided.
#' @seealso \href{https://docs.newrelic.com/docs/apis/rest-api-v2/requirements/new-relic-rest-api-v2-getting-started}{New Relic REST API Documentation}
#' @seealso \href{https://docs.newrelic.com/docs/apis/rest-api-v2/requirements/api-keys}{How to get API keys}
#' @return a data table with observations as timeslices and the timeslice start time, metric name, and values in the variables
#' @examples
#'     rpm_query(account_id=12345, api_key='your_api_license_key_here',
#'               app_id=-1, duration=3600, period=300, end_time=as.POSIXct('2016-01-28 09:15:00'),
#'               metrics='HttpDispatcher', values='calls_per_minute')
#' @export
rpm_query <- function(account_id,
                      api_key,
                      app_id,
                      duration=60 * 60,
                      end_time=Sys.time(),
                      period=NULL,
                      metrics='HttpDispatcher',
                      verbose=F,
                      values='average_response_time',
                      cache=T,
                      host='api.newrelic.com',
                      progress_callback=NULL,
                      ...) {

    metrics <- as.list(metrics)
    names(metrics) <- rep('names[]', length(metrics))

    values <- as.list(values)
    names(values) <- rep('values[]', length(values))

    query <- append(metrics, values)

    if (!lubridate::is.duration(period)) {
        period <- lubridate::dseconds(period)
    }
    if (is.null(period)) {
        fetch_size <- lubridate::dseconds(duration)
    } else if (period >= lubridate::dhours(1)) {
        fetch_size <- lubridate::ddays(7)
    } else if (period >= lubridate::dminutes(10)) {
        fetch_size <- lubridate::dhours(24)
    } else if (period >= lubridate::dminutes(1)) {
        fetch_size <- lubridate::dhours(3)
    } else {
        stop("Period must be greater than 60 seconds: ", period)
    }
    start_time <- end_time - duration
    if (!is.null(period) &&
        period < lubridate::dhours(1) &&
        start_time < Sys.time() - lubridate::days(8)) {
        stop("You can't have a period less than 60 minutes when getting data older than 8 days: ",
             start_time)
    }

    if (is.null(end_time)) end_time <- Sys.time()
    num_chunks <- (end_time - start_time) / lubridate::as.duration(fetch_size)
    chunk.start <- start_time
    chunk.end <- min(end_time, chunk.start + fetch_size)
    query <- append(query,
                    list( period=as.numeric(period),
                          raw=TRUE))

    key <- digest::digest(c(query, as.numeric(start_time), as.numeric(end_time)))
    cachefile <- paste('query_cache/', key, '.RData', sep='')
    if (cache & file.exists(cachefile)) {
        data <- readRDS(file=cachefile)
        if (verbose) message('read cached: ', cachefile)
        return(data)
    }
    if (num_chunks > 5 && verbose) message("Sending ", ceiling(num_chunks), " queries...")
    progress_count <- 0
    if (!is.null(progress_callback)) {
        progress_callback(progress_count, num_chunks)
    }
    chunks <- list()
    repeat {
        query['from'] <- to_json_time(chunk.start)
        query['to'] <-  to_json_time(chunk.end)

        data <- send_query(app_id,
                           host,
                           query,
                           api_key,
                           cache,
                           verbose)

        chunks[[length(chunks)+1]] <- data
        if (!is.null(progress_callback)) {
            progress_callback(progress_count, num_chunks)
        }
        if (chunk.end < end_time) {
            chunk.start <- chunk.end
            chunk.end <- min(end_time, chunk.start + fetch_size)
        } else {
            break
        }
    }
    data <- dplyr::bind_rows(chunks)
    if (cache) {
        if (!dir.exists(dirname(cachefile))) dir.create(dirname(cachefile))
        saveRDS(data, file=cachefile)
        if (verbose) message('write cache: ', cachefile)
    }
    return(data)
}
#' Query for New Relic Applications.
#'
#' This function returns a list of applications in the given account.
#'
#' @param account_id your New Relic account ID
#' @param api_key your New Relic APM REST API key
#' @param verbose show extra information about the calls
#' @param host use to proxy requests through an intermediate host you can override the default host
#'     of \code{api.newrelic.com}.
#' @return a data table with observations for each application and variables for the id, name, and throughput
#' @export
rpm_applications <- function(account_id,
                             api_key,
                             host='api.newrelic.com',
                             verbose=F) {
    page <- 1
    df <- data.frame()
    repeat {
        response <- httr::GET(paste("https://", host, "/v2/applications.json", sep = ""),
                              as='text',
                              query=list(page=page),
                              httr::config(verbose=verbose),
                              httr::accept("application/json"),
                              httr::add_headers('X-Api-Key'=api_key))
        result <- httr::content(response)
        if (!is.null(result$error)) {
            stop("Error in response: ", result$error)
        }
        chunk <- dplyr::bind_rows(lapply(result$applications, function(app) {
            throughput <- if (app$reporting) app$application_summary$throughput else 0
            data.frame(id=app$id,
                       name=app$name,
                       throughput=throughput,
                       stringsAsFactors = F)
        }))
        df <- dplyr::bind_rows(df, chunk)
        if (nrow(chunk) < 200) break
        page <- page + 1
    }
    dplyr::arrange(dplyr::filter(df, throughput > 0),
                   desc(throughput))
}

## Utility functions

send_query <- function(app_id,
                       host,
                       query,
                       api_key,
                       cache,
                       verbose) {
    if (app_id < 1) {
        url <- 'http://mockbin.org/bin/1ba023e7-d63c-4e92-a4af-bedb93e9aa98'
    } else {
        url <- paste("https://", host, "/v2/applications/",
                     app_id,"/metrics/data.json",
                     sep = '')
    }

    key <- digest::digest(c(url, unlist(unname(query))))
    cachefile <- paste('query_cache/', key, '.RData', sep='')

    response <- httr::GET(url,
                          query=query,
                          as='text',
                          httr::config(verbose=verbose),
                          httr::accept("application/json"),
                          httr::add_headers('X-Api-Key'=api_key))
    result <- httr::content(response, type='application/json')
    if (!is.null(result$error)) {
        stop("Error in response: ", result$error)
    }
    metric_data_frames <- lapply(result$metric_data$metrics, parse_metricdata)
    dplyr::bind_rows(metric_data_frames)
}

to_json_time <- function(time) { strftime(time, '%Y-%m-%dT%H:%M:00%z') }
from_json_time <- function(timestr) { lubridate::ymd_hms(timestr, tz='America/Los_Angeles', quiet = T)}
parse_metricdata <- function(metric_timeslices) {
    ts_index <- data.frame(name=metric_timeslices$name,
                           start=from_json_time(sapply(metric_timeslices$timeslices, function(ts) ts$from)),
                           stringsAsFactors=F)
    dplyr::bind_cols(ts_index, data.table::rbindlist(lapply(metric_timeslices$timeslices, function(e) e$values)))
}
