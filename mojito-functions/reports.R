#
# Mojito reports functions
#

library("ggplot2")
library("scales")
library("reshape")
library("ztable")
library("dplyr")
library("stats")


# Report options
options(ztable.type="html")
if ((is.na(Sys.timezone()) || is.null(Sys.timezone())) && !exists("mojitoReportTimezone")) {
  stop("Mojito Reports: Set your R timezone or supply an override e.g. 'Australia/Melbourne' via the `mojitoReportTimezone` variable")
} else {
  mojitoReportTimezone <- Sys.timezone()
}



# Date formatting at the top of the report
mojitoReportDates <- function(wave_params) {
  ifelse(as.POSIXct(wave_params$stop_date,mojitoReportTimezone)<Sys.time(),
    return(
      paste0(
        wave_params$stop_date,
        " (Ran for ",floor(difftime(as.POSIXct(wave_params$stop_date,mojitoReportTimezone), 
        as.POSIXct(wave_params$start_date,mojitoReportTimezone), units = "days")),
        " days)"
        )
      ),
    return(
      paste0(
        "Still active (Running for ",
        floor(difftime(Sys.time(), as.POSIXct(wave_params$start_date,mojitoReportTimezone), units = "days")),
        " days)"
        )
      )
    )
}


# Handle ETA estimates formatting
mojitoReportExperimentSizing <- function(conversion_point) {
  if (exists("wave_eta")) {
    return(
      paste0(
        round(wave_eta$estimate_data$days_to_run, 1), " days",
        " w/ ", percent(wave_eta$delta), " MDE in ", conversion_point,
        " and ~", comma(round(wave_eta$estimate_data$subjects/wave_eta$recipes, 0)), " subjects/recipe."
      )
    )
  }
}


# SRM test
# Check for assignment issues with Ron Kohavi's SRM check: https://twitter.com/ronnyk/status/932798952679776256?lang=en
mojitoSrmTest <- function(wave_params, dailyDf, expected_ratio=0.5) {
  # Get the last two fields in the dailyDf dataframe and order results if recipes are specified
  df <- tail(
    dailyDf,
    length(wave_params$recipes)
  )[,-1]

  actual_ratio <- df$subjects[1] / sum(df$subjects)
  srm_z <- (actual_ratio - expected_ratio) / (sqrt( expected_ratio * (1-expected_ratio) / sum(df$subjects) ))
  srm_p <- 2 * (1-pnorm(srm_z))

  return(srm_p)

}


# Diagnotics plot & SRM test
# Useful for diagnosing bad assignment ratios and tracking issues
mojitoDiagnostics <- function(wave_params, dailyDf) {

  # Plot exposed users per time grain
  exposed_users <- dailyDf %>%
    group_by(recipe_name) %>%
    mutate(exposed = c(subjects[1], diff(subjects)))

  exposed_plot <- ggplot(exposed_users, aes(exposure_time, exposed, color=recipe_name)) +
    geom_line(stat="identity") + scale_y_log10() +
    ylab("Subjects") + xlab("Exposure time") +
    scale_color_discrete(guide=F)

  # Plot SRM
  srmplot_data <- dailyDf %>%
    group_by(exposure_time) %>%
    mutate(total_subjects = sum(subjects, na.rm=T)) %>%
    ungroup()
  
  srmplot_data$ratio <- srmplot_data$subjects / srmplot_data$total_subjects
  
  srm_plot <- ggplot(srmplot_data) + 
    geom_line(aes(exposure_time, ratio, color=recipe_name), stat="identity") +
    ylab("Ratio") + xlab("Exposure time") +
    scale_alpha(guide=F) + theme(legend.position = "bottom", legend.title = element_blank())

  srm_metric <- mojitoSrmTest(wave_params = wave_params, dailyDf = dailyDf, expected_ratio = 1/length(wave_params$recipes))
  
  print(exposed_plot)
  print(srm_plot)
  print(paste0("SRM p-value (proportion assigned to Control is evenly assigned?): ", srm_metric, " (",ifelse(srm_metric<0.001,"No", "Yes"),")"))


  # Plot and output errors if available
  error_plot_data <- mojitoGetErrorsChart(wave_params)
  if (length(error_plot_data) == 4) {
    cat(paste0("<br /><h3>Errors tracked</h3>"))
    error_plot <- ggplot(error_plot_data, aes(tstamp, color=component)) +
      geom_line(aes(y=subjects)) +
      xlab(NULL) + ylab("Errors") + theme(legend.position="bottom")
    print(error_plot)

    tab_data <- mojitoGetErrorsTab(wave_params)
    colnames(tab_data) <- c("Component", "Error message", "Total errors", "Subjects")
    knitr::kable(tab_data, format = "html")
  }
}


# Unique conversions report
# Plot p-value / delta charts and a summary table for a given metric/segment combination
mojitoUniqueConversions <- function(wave_params, goal, operand="=", goal_count=1, segment=NA, segment_val_operand="=", segment_negative=TRUE) {

  tryCatch({
    result <- mojitoGetUniqueConversions(wave_params, goal, operand=operand, goal_count, segment, segment_val_operand, segment_negative)
    last_result <<- result
  }, error = function(e){
    print(paste("Error:",e))
  })

  # Populate recipe names for convenience
  if (!("recipes" %in% names(wave_params))) {
    wave_params$recipes <- unique(result$recipe_name)
  }

  # Run plots & table
  if (exists("result")) {
    tryCatch({
      mojitoPlotUniqueDelta(wave_params, result)
      mojitoTabUniqueCvr(wave_params, result)
    }, error = function(e){
      print(paste("Error - check your data.",e))
      print(result)
      print(wave_params)
    })  
  }
}



# Create the full knit from the goal_list
# Pass in a list of goals to iterate through
mojitoFullKnit <- function(wave_params, goal_list=NA) {
  for (i in 1:length(lapply(goal_list, "["))) {

    itemList <- lapply(goal_list, "[")[[i]]
    
    if (!is.null(itemList$segment_type) && itemList$segment_type == "traffic") {
      # Traffic segments data
      goal_list[[i]]$result <- mojitoGetUniqueTrafficConversions(
        wave_params=wave_params, 
        goal=itemList$goal, 
        operand=itemList$operand, 
        goal_count=ifelse(is.null(itemList$goal_count),1,itemList$goal_count),
        segment_type=ifelse(is.null(itemList$segment_type),NA,itemList$segment_type),
        segment_value=ifelse(is.null(itemList$segment_value),NA,itemList$segment_value)
      )
    } else {
      # Standard conversions data
      goal_list[[i]]$result <- mojitoGetUniqueConversions(
        wave_params=wave_params, 
        goal=itemList$goal, 
        operand=itemList$operand, 
        goal_count=ifelse(is.null(itemList$goal_count),1,itemList$goal_count),
        segment_type=ifelse(is.null(itemList$segment_type),NA,itemList$segment_type),
        segment_value=ifelse(is.null(itemList$segment_value),NA,itemList$segment_value), 
        segment_val_operand=ifelse(is.null(itemList$segment_val_operand), "=", itemList$segment_val_operand), 
        segment_negative=ifelse(is.null(itemList$segment_negative), F, itemList$segment_negative)
      )
      rowResult <- mojitoSummaryTableRows(goal_list[[i]]$result, wave_params = wave_params, goal_list=goal_list[[i]])

      if (exists("summaryDf")) {
        summaryDf <- rbind(summaryDf, rowResult)
      } else {
        summaryDf <- rowResult
      }

    }
  
  }
  
  # Summary table print
  if (exists("summaryDf")) mojitoTabulateSummaryDf(summaryDf)
  
  # Print sections of the report
  for (i in 1:length(lapply(goal_list, "["))) {
    cat(paste0("<br /><h2>", goal_list[[i]]$title, "</h2>"))
    if (!is.null(goal_list[[i]]$segment_type) && goal_list[[i]]$segment_type == "traffic") {
      # Traffic segments table
      mojitoTabUniqueTrafficCvr(wave_params, goal_list[[i]]$result)
    } else {
      # Standard unique conversions plot
      mojitoPlotUniqueDelta(wave_params, goal_list[[i]]$result)
      cat("<br />")
      mojitoTabUniqueCvr(wave_params, goal_list[[i]]$result)
    }
  }
  
  return(goal_list)
  
}
