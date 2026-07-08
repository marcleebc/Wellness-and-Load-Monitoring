## ---------------------------------------------------------------------------
## Squad Wellness & Training Load - Daily Summary
##
## Simple Shiny dashboard showing, for a selected day, a single combined
## chart: each athlete's wellness metric (pick one from the dropdown) as a
## dot, and training load (AU) as a bar, both plotted as Z-scores against
## the squad average for that day.
##
## Data is read live from the two Google Sheets that back the "Daily
## Wellness Form" and "RPE Form", using a Google service account. Locally,
## the credential comes from gs_service_account.json in this folder. When
## deployed on Posit Connect Cloud (which needs a public GitHub repo on the
## free tier), that file is never committed to git - instead the app reads
## the same JSON from the GS_SERVICE_ACCOUNT_JSON environment variable,
## which you set in Connect Cloud's "Configure variables" screen at publish
## time. See README.md for the full deploy steps.
## ---------------------------------------------------------------------------

library(shiny)
library(googlesheets4)
library(dplyr)
library(tidyr)
library(tibble)
library(ggplot2)
library(scales)

## --- Configuration ----------------------------------------------------------

# NOTE: this ID was pointing at a leftover sheet from an earlier version of
# the project (different question wording, a "Mood" question, no real
# responses) until this fix - it's now the actual "Morning Wellness
# Check-in (Responses)" sheet you've been using.
WELLNESS_SHEET_ID <- "1h4tHdzhql7S324ADBNaj8ndi8_Wh_5xAcx7LWMtc3WQ"
# Same story here: this used to point at a leftover "Post-Match RPE Log"
# sheet with pre-calculated load columns that don't exist on your real form.
# It's now the actual "RPE Form (Responses)" sheet.
RPE_SHEET_ID       <- "1PZrYiLv_3r32a7IGvdX72CXTGYw-Z--sr3m9Rjbqje4"
SHEET_TAB          <- "Form responses 1"

KEY_FILE <- "gs_service_account.json"
# On Connect Cloud (or anywhere else that can't have the raw JSON file
# committed to a public repo), set this environment variable to the full
# contents of gs_service_account.json instead. Locally it'll be unset, so
# the app just falls back to reading the file straight off disk.
GS_SERVICE_ACCOUNT_JSON <- Sys.getenv("GS_SERVICE_ACCOUNT_JSON", unset = "")

# Positional column names (these sheets were built with a fixed column order,
# so we rename by position rather than relying on the long descriptive
# header text, which is easy to typo-mismatch).
#
# Wellness sheet layout (confirmed against the live sheet, Jul 2026):
#   A timestamp | B athlete | C date
#   D fatigue (text answer)  | E stress (text answer)
#   F sleep (text answer)    | G soreness (text answer)
#   H notes (injuries/concerns, free text)
#   I fatigue 1-7 (numeric, converted from D) | J stress 1-7 (from E)
#   K sleep 1-7 (from F)                      | L soreness 1-7 (from G)
#   M wellness (left blank in the sheet - we compute a total below instead)
#
# Numeric scale for all four: 1 = Very very good ... 7 = Very very Bad, so
# LOWER is better on every one of these.
WELLNESS_COLS <- c(
  "timestamp", "athlete", "date",
  "fatigue_text", "stress_text", "sleep_text", "soreness_text", "notes",
  "fatigue", "stress", "sleep", "soreness", "wellness"
)

# RPE sheet layout (confirmed against the live "RPE Form (Responses)"
# sheet, Jul 2026): A timestamp | B athlete | C date | D duration (minutes)
# | E rpe (0-10) | F session_type | G comments | H email. There's no
# pre-calculated session load or the acute/chronic/ACR/monotony/strain
# metrics that were assumed before - we compute session load ourselves
# (duration x RPE, the standard session-RPE training load formula).
RPE_COLS <- c(
  "timestamp", "athlete", "date",
  "duration_min", "rpe", "session_type", "comments", "email"
)

WELLNESS_METRICS <- c(
  "Fatigue"               = "fatigue",
  "Stress"                = "stress",
  "Sleep"                 = "sleep",
  "Muscle Soreness"       = "soreness",
  "Total Wellness Score"  = "total_wellness_score"
)

## --- Auth --------------------------------------------------------------------

# gs4_auth()'s path argument accepts either a path to a JSON file, or the
# JSON contents themselves as a string - so the same call works whether
# we're running locally off the file, or on Connect Cloud off the env var.
if (nzchar(GS_SERVICE_ACCOUNT_JSON)) {
  gs4_auth(path = GS_SERVICE_ACCOUNT_JSON)
} else {
  gs4_auth(path = KEY_FILE)
}

## --- Data loading --------------------------------------------------------------

# Build a per-column type string for range_read(), e.g. "ccDcccccccccc",
# with the Date question forced to real type "D" (column 3 on both sheets:
# timestamp, athlete, date, ...). This matters because forcing every column
# to plain character ("c") can make googlesheets4 hand back the *raw*
# underlying serial number for a genuine Date-typed cell (something like
# "46944") instead of a readable string - which silently broke date
# filtering no matter what date you picked. Asking for "D" explicitly makes
# googlesheets4 parse it as a real date correctly, regardless of the
# spreadsheet's locale/display format.
col_types_for <- function(col_names, date_pos = 3) {
  types <- rep("c", length(col_names))
  types[date_pos] <- "D"
  paste(types, collapse = "")
}

# safe_read now returns a list(df, raw_names, raw_ncol, error) instead of
# just a data frame, so we can surface *what actually happened* in a
# Diagnostics panel in the app itself - this is much more useful than an R
# console warning that's easy to miss, especially if you're not the one who
# wrote the code.
safe_read <- function(sheet_id, col_names, col_types) {
  # Read an explicit column range ("A:M" etc.) instead of letting
  # range_read() auto-detect the used range. Both of these sheets show up
  # as a Google Sheets "Table" object (visible as a chip in the top-left
  # corner), and that newer Tables feature seems to confuse googlesheets4's
  # auto-detection - it was reporting fewer columns than actually exist.
  # Being explicit about the range sidesteps that entirely.
  last_col_letter <- LETTERS[length(col_names)]
  full_range <- paste0("'", SHEET_TAB, "'!A:", last_col_letter)

  result <- tryCatch(
    {
      df <- range_read(sheet_id, range = full_range, col_names = TRUE, col_types = col_types)
      list(df = df, raw_names = names(df), error = NULL)
    },
    error = function(e) {
      empty <- as.data.frame(setNames(replicate(length(col_names), character(0), simplify = FALSE), col_names))
      list(df = empty, raw_names = NULL, error = conditionMessage(e))
    }
  )
  df <- result$df
  if (nrow(df) == 0 && is.null(result$error)) {
    df <- as.data.frame(matrix(character(), nrow = 0, ncol = length(col_names)))
  }
  raw_ncol <- ncol(df)
  names(df) <- col_names[seq_len(min(ncol(df), length(col_names)))]

  # If fewer columns came back than expected, pad the missing ones with NA
  # instead of silently leaving them off - otherwise code further down that
  # references a specific column by name (e.g. df$soreness) would error out
  # with "undefined columns" instead of showing a clear message.
  missing_cols <- setdiff(col_names, names(df))
  for (mc in missing_cols) {
    df[[mc]] <- NA_character_
  }

  list(df = df, raw_names = result$raw_names, raw_ncol = raw_ncol, error = result$error)
}

load_wellness <- function() {
  rr <- safe_read(WELLNESS_SHEET_ID, WELLNESS_COLS, col_types_for(WELLNESS_COLS))
  df <- rr$df
  diag <- list(error = rr$error, raw_names = rr$raw_names, raw_ncol = rr$raw_ncol,
               expected_ncol = length(WELLNESS_COLS), rows_read = nrow(df))

  df <- df[!is.na(df$timestamp) & df$timestamp != "", , drop = FALSE]
  diag$rows_after_filter <- nrow(df)

  if (nrow(df) > 0) {
    df$athlete <- trimws(df$athlete)
    df$date <- as.Date(df$date)

    for (col in c("fatigue", "stress", "sleep", "soreness")) {
      df[[col]] <- suppressWarnings(as.numeric(df[[col]]))
    }

    # The sheet's own "wellness" column (M) is left blank, so we compute a
    # total wellness score ourselves as the mean of the four 1-7 sub-scores
    # (lower = better, same direction as the individual metrics).
    df$total_wellness_score <- rowMeans(df[, c("fatigue", "stress", "sleep", "soreness")], na.rm = TRUE)
  }

  diag$date_class  <- class(df$date)[1]
  diag$date_values <- if (nrow(df) > 0) paste(format(df$date), collapse = ", ") else "(no rows)"
  diag$athletes    <- if (nrow(df) > 0) paste(unique(df$athlete), collapse = ", ") else "(none)"

  list(df = df, diag = diag)
}

load_rpe <- function() {
  rr <- safe_read(RPE_SHEET_ID, RPE_COLS, col_types_for(RPE_COLS))
  df <- rr$df
  diag <- list(error = rr$error, raw_names = rr$raw_names, raw_ncol = rr$raw_ncol,
               expected_ncol = length(RPE_COLS), rows_read = nrow(df))

  df <- df[!is.na(df$timestamp) & df$timestamp != "", , drop = FALSE]
  diag$rows_after_filter <- nrow(df)

  if (nrow(df) > 0) {
    df$athlete <- trimws(df$athlete)
    df$date <- as.Date(df$date)
    df$duration_min <- suppressWarnings(as.numeric(df$duration_min))
    df$rpe <- suppressWarnings(as.numeric(df$rpe))

    # The sheet doesn't have a pre-calculated load column, so we compute the
    # standard session-RPE training load ourselves: duration (min) x RPE.
    df$session_load <- df$duration_min * df$rpe
  }

  diag$date_class  <- class(df$date)[1]
  diag$date_values <- if (nrow(df) > 0) paste(format(df$date), collapse = ", ") else "(no rows)"
  diag$athletes    <- if (nrow(df) > 0) paste(unique(df$athlete), collapse = ", ") else "(none)"
  diag$load_sample <- if (nrow(df) > 0) paste(sprintf("%s: dur=%s rpe=%s load=%s", df$athlete, df$duration_min, df$rpe, df$session_load), collapse = " | ") else "(no rows)"

  list(df = df, diag = diag)
}

## --- UI ------------------------------------------------------------------------

ui <- fluidPage(
  title = "Squad Daily Summary",
  tags$head(tags$style(HTML("
    body { font-family: -apple-system, Helvetica, Arial, sans-serif; }
    h2 { margin-top: 0; }
    .section-title { background:#1a56b0; color:#fff; padding:8px 12px; font-weight:600; margin-top:24px; }
    .well { background:#f7f7f8; }
  "))),
  fluidRow(
    column(12,
      h2("Squad Daily Summary"),
      div(style = "display:flex; gap:16px; align-items:center; flex-wrap:wrap;",
        dateInput("summary_date", "Date", value = Sys.Date()),
        actionButton("refresh", "Refresh data", icon = icon("refresh"))
      ),
      textOutput("last_updated")
    )
  ),
  div(class = "section-title", "Individual Wellness vs Group"),
  fluidRow(
    column(4,
      div(class = "well",
        selectInput("wellness_metric", "Wellness metric",
                    choices = names(WELLNESS_METRICS), selected = "Fatigue")
      )
    )
  ),
  fluidRow(
    column(12, plotOutput("wellness_zscore_plot", height = "380px"))
  ),
  div(class = "section-title", "Individual Load vs Group"),
  fluidRow(
    column(12, plotOutput("load_bar_plot", height = "420px"))
  ),
  div(class = "section-title", "Individual Wellness vs Load"),
  fluidRow(
    column(12, plotOutput("combined_plot", height = "450px"))
  ),
  div(class = "section-title", "Weekly Load & Wellness"),
  fluidRow(
    column(3, div(class = "well", uiOutput("weekly_week_ui"))),
    column(3, div(class = "well",
      selectInput("weekly_metric", "Wellness metric",
                  choices = names(WELLNESS_METRICS), selected = "Fatigue")
    )),
    column(3, div(class = "well", uiOutput("weekly_athlete_ui")))
  ),
  fluidRow(
    column(12, plotOutput("weekly_plot", height = "420px"))
  ),
  div(class = "section-title", "Diagnostics (for troubleshooting - copy/paste this back if a chart looks wrong)"),
  fluidRow(
    column(12,
      actionButton("toggle_diag", "Show diagnostics"),
      uiOutput("diagnostics_container")
    )
  )
)

## --- Server -------------------------------------------------------------------

server <- function(input, output, session) {

  wellness_result <- reactiveVal(load_wellness())
  rpe_result      <- reactiveVal(load_rpe())
  last_refresh    <- reactiveVal(Sys.time())

  wellness_raw <- reactive(wellness_result()$df)
  rpe_raw      <- reactive(rpe_result()$df)

  observeEvent(input$refresh, {
    wellness_result(load_wellness())
    rpe_result(load_rpe())
    last_refresh(Sys.time())
  })

  output$last_updated <- renderText({
    paste("Data last refreshed:", format(last_refresh(), "%d %b %Y, %H:%M"))
  })

  # Plain Shiny reactivity for the show/hide toggle instead of any custom
  # JS (an HTML <details>/<summary> element, then an inline onclick handler,
  # both failed to be clickable in this RStudio Viewer setup). This uses the
  # exact same actionButton + observeEvent machinery as the Refresh button,
  # which is already known to work here.
  diag_visible <- reactiveVal(FALSE)

  observeEvent(input$toggle_diag, {
    diag_visible(!diag_visible())
    updateActionButton(session, "toggle_diag",
                        label = if (diag_visible()) "Hide diagnostics" else "Show diagnostics")
  })

  output$diagnostics_container <- renderUI({
    if (diag_visible()) {
      verbatimTextOutput("diagnostics")
    } else {
      NULL
    }
  })

  output$diagnostics <- renderPrint({
    w <- wellness_result()$diag
    r <- rpe_result()$diag

    cat("WELLNESS SHEET\n")
    cat("  read error:          ", ifelse(is.null(w$error), "(none)", w$error), "\n")
    cat("  columns from sheet:  ", ifelse(is.null(w$raw_names), "(none - read failed)", paste(w$raw_names, collapse = " | ")), "\n")
    cat("  column count:        ", w$raw_ncol, " (app expects", w$expected_ncol, ")\n")
    cat("  rows read:           ", w$rows_read, "\n")
    cat("  rows after filter:   ", w$rows_after_filter, "\n")
    cat("  date column class:   ", w$date_class, "\n")
    cat("  date values seen:    ", w$date_values, "\n")
    cat("  athletes seen:       ", w$athletes, "\n")
    cat("\n")
    cat("RPE / LOAD SHEET\n")
    cat("  read error:          ", ifelse(is.null(r$error), "(none)", r$error), "\n")
    cat("  columns from sheet:  ", ifelse(is.null(r$raw_names), "(none - read failed)", paste(r$raw_names, collapse = " | ")), "\n")
    cat("  column count:        ", r$raw_ncol, " (app expects", r$expected_ncol, ")\n")
    cat("  rows read:           ", r$rows_read, "\n")
    cat("  rows after filter:   ", r$rows_after_filter, "\n")
    cat("  date column class:   ", r$date_class, "\n")
    cat("  date values seen:    ", r$date_values, "\n")
    cat("  athletes seen:       ", r$athletes, "\n")
    cat("  duration/rpe/load:   ", r$load_sample, "\n")
    cat("\n")
    cat("Date currently selected in the app:", format(input$summary_date), "\n")
  })

  # ---- Weekly Load & Wellness chart ----

  # Week selector: choices are "the Monday of each week that has data",
  # labeled as "Week of <that Monday's date>". %u gives ISO weekday
  # (1=Mon..7=Sun), so subtracting (weekday - 1) days from any date lands
  # on that date's Monday.
  output$weekly_week_ui <- renderUI({
    dates <- sort(unique(c(wellness_raw()$date, rpe_raw()$date)))
    dates <- dates[!is.na(dates)]
    if (length(dates) == 0) {
      return(selectInput("weekly_week", "Week (starting Monday)", choices = c("No data yet" = "")))
    }
    mondays <- sort(unique(dates - (as.integer(format(dates, "%u")) - 1)))
    choices <- setNames(as.character(mondays), paste0("Week of ", format(mondays, "%d %b %Y")))
    current <- isolate(input$weekly_week)
    selected <- if (!is.null(current) && current %in% choices) current else unname(tail(choices, 1))
    selectInput("weekly_week", "Week (starting Monday)", choices = choices, selected = selected)
  })

  # Player selector: blank option means "team average" (the default).
  output$weekly_athlete_ui <- renderUI({
    athletes <- sort(unique(c(wellness_raw()$athlete, rpe_raw()$athlete)))
    athletes <- athletes[!is.na(athletes) & athletes != ""]
    choices <- c("All (group average)" = "", athletes)
    current <- isolate(input$weekly_athlete)
    selected <- if (!is.null(current) && current %in% choices) current else ""
    selectInput("weekly_athlete", "Player", choices = choices, selected = selected)
  })

  output$weekly_plot <- renderPlot({
    validate(need(!is.null(input$weekly_week) && nzchar(input$weekly_week),
                  "No wellness or load data available yet to pick a week from."))

    monday <- as.Date(input$weekly_week)
    week_dates <- monday + 0:6
    weekday_labels <- c("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

    metric_col <- WELLNESS_METRICS[[input$weekly_metric]]
    athlete_sel <- input$weekly_athlete
    if (is.null(athlete_sel)) athlete_sel <- ""

    w_df <- wellness_raw()
    r_df <- rpe_raw()

    # ---- Load per day: either one athlete's daily total, or the team's
    # daily average (mean of each responding athlete's daily total) ----
    r_week <- r_df %>% filter(date %in% week_dates)
    if (nzchar(athlete_sel)) {
      load_by_day <- r_week %>%
        filter(athlete == athlete_sel) %>%
        group_by(date) %>%
        summarise(load = sum(session_load, na.rm = TRUE), .groups = "drop")
    } else {
      load_by_day <- r_week %>%
        group_by(date, athlete) %>%
        summarise(daily = sum(session_load, na.rm = TRUE), .groups = "drop") %>%
        group_by(date) %>%
        summarise(load = mean(daily, na.rm = TRUE), .groups = "drop")
    }

    # ---- Wellness per day: either one athlete's value, or the team
    # average of each athlete's value that day ----
    w_week <- w_df %>% filter(date %in% week_dates)
    if (nzchar(athlete_sel)) {
      wellness_by_day <- w_week %>%
        filter(athlete == athlete_sel) %>%
        group_by(date) %>%
        summarise(wellness = dplyr::last(.data[[metric_col]]), .groups = "drop")
    } else {
      wellness_by_day <- w_week %>%
        group_by(date, athlete) %>%
        summarise(daily = dplyr::last(.data[[metric_col]]), .groups = "drop") %>%
        group_by(date) %>%
        summarise(wellness = mean(daily, na.rm = TRUE), .groups = "drop")
    }

    week_df <- tibble(date = week_dates, weekday = factor(weekday_labels, levels = weekday_labels)) %>%
      left_join(load_by_day, by = "date") %>%
      left_join(wellness_by_day, by = "date")

    validate(need(any(!is.na(week_df$load)) || any(!is.na(week_df$wellness)),
                  "No load or wellness data for this week yet."))

    # Wellness is always on a fixed 1-7 scale, so it's rescaled onto
    # whatever range the load bars are using, then a secondary axis on the
    # right translates back to the real 1-7 scale for reading.
    max_load <- suppressWarnings(max(week_df$load, na.rm = TRUE))
    axis_max <- if (!is.finite(max_load) || max_load <= 0) 10 else max_load * 1.15
    week_df <- week_df %>% mutate(wellness_scaled = (wellness - 1) / 6 * axis_max)

    title_who <- if (nzchar(athlete_sel)) athlete_sel else "Team Average"

    ggplot(week_df, aes(x = weekday)) +
      geom_col(aes(y = load, fill = "Load"), width = 0.6, na.rm = TRUE) +
      geom_text(aes(y = load, label = ifelse(is.na(load), "", round(load))),
                vjust = -0.5, size = 3.5, na.rm = TRUE) +
      geom_line(aes(y = wellness_scaled, group = 1, color = "Wellness"),
                linetype = "dashed", linewidth = 0.8, na.rm = TRUE) +
      geom_point(aes(y = wellness_scaled, color = "Wellness"), size = 3, na.rm = TRUE) +
      scale_fill_manual(name = NULL, values = c("Load" = "#5B8FD6")) +
      scale_color_manual(name = NULL, values = c("Wellness" = "#E8792A")) +
      scale_y_continuous(
        name = "Load (AU)", limits = c(0, axis_max),
        sec.axis = sec_axis(~ . / axis_max * 6 + 1,
                             name = paste0(input$weekly_metric, " (1-7, lower = better)"))
      ) +
      labs(x = NULL,
           title = paste0("Weekly Load & ", input$weekly_metric, " - ", title_who,
                           " - Week of ", format(monday, "%d %b %Y"))) +
      theme_minimal(base_size = 13) +
      theme(plot.title = element_text(face = "bold"),
            legend.position = "top",
            legend.title = element_blank())
  })

  # ---- Wellness Z-score plot (standalone, same dropdown as the combined chart) ----
  output$wellness_zscore_plot <- renderPlot({
    df <- wellness_raw()
    metric_col <- WELLNESS_METRICS[[input$wellness_metric]]
    validate(need(nrow(df) > 0, "No wellness responses recorded yet."))

    day_df <- df %>%
      filter(date == input$summary_date) %>%
      group_by(athlete) %>%
      summarise(value = dplyr::last(.data[[metric_col]]), .groups = "drop") %>%
      filter(!is.na(value))

    validate(need(nrow(day_df) > 0, "No wellness responses for this date yet."))
    validate(need(nrow(day_df) > 1, "Need at least 2 athletes' responses on this date to compute a group Z-score."))

    grp_mean <- mean(day_df$value)
    grp_sd   <- sd(day_df$value)
    validate(need(grp_sd > 0, "All responses identical on this date - no spread to compute Z-scores."))

    day_df <- day_df %>%
      mutate(z = (value - grp_mean) / grp_sd) %>%
      arrange(athlete) %>%
      mutate(athlete = factor(athlete, levels = athlete))

    ggplot(day_df, aes(x = athlete, y = z)) +
      annotate("rect", xmin = -Inf, xmax = Inf, ymin = -0.5, ymax = 0.5,
               fill = "grey70", alpha = 0.4) +
      geom_hline(yintercept = 0, color = "grey30", linewidth = 0.6) +
      geom_point(size = 4, color = "#E8792A") +
      scale_y_continuous(limits = function(l) c(min(-2, l[1]), max(2, l[2]))) +
      labs(x = NULL, y = "Z Score",
           title = paste0("Individual ", input$wellness_metric, " vs Group - ", format(input$summary_date, "%d %b %Y")),
           caption = "Scale runs good-to-bad, so a higher Z score here means worse than the group.") +
      theme_minimal(base_size = 13) +
      theme(axis.text.x = element_text(angle = 45, hjust = 1),
            plot.title = element_text(face = "bold"))
  })

  # ---- Load bar chart with group average reference line ----
  output$load_bar_plot <- renderPlot({
    df <- rpe_raw()
    validate(need(nrow(df) > 0, "No RPE / load responses recorded yet."))

    day_df <- df %>%
      filter(date == input$summary_date) %>%
      group_by(athlete) %>%
      summarise(value = sum(session_load, na.rm = TRUE), .groups = "drop") %>%
      filter(!is.na(value))

    validate(need(nrow(day_df) > 0, "No RPE / load responses for this date yet."))

    grp_mean <- mean(day_df$value)

    day_df <- day_df %>%
      arrange(athlete) %>%
      mutate(athlete = factor(athlete, levels = athlete))

    ggplot(day_df, aes(x = athlete, y = value)) +
      geom_col(aes(fill = "Load"), width = 0.6) +
      geom_text(aes(label = round(value)), vjust = -0.5, size = 3.5) +
      geom_hline(data = data.frame(grp_mean = grp_mean),
                 aes(yintercept = grp_mean, color = "Group Average"),
                 linetype = "dashed", linewidth = 0.8) +
      scale_fill_manual(name = NULL, values = c("Load" = "#5B8FD6")) +
      scale_color_manual(name = NULL, values = c("Group Average" = "#E8792A")) +
      scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
      labs(x = NULL, y = "Load (AU)",
           title = paste0("Individual Load vs Group - ", format(input$summary_date, "%d %b %Y"))) +
      theme_minimal(base_size = 13) +
      theme(axis.text.x = element_text(angle = 45, hjust = 1),
            plot.title = element_text(face = "bold"),
            legend.position = "top",
            legend.title = element_blank())
  })

  # ---- Combined Wellness + Load Z-score chart ----
  # Wellness (dots) and Load (bars) are each Z-scored against their own
  # group - the set of athletes with a response for that metric on the
  # selected date - since the two forms can have different responders on
  # any given day. They're then plotted together on one chart via
  # full_join, so an athlete missing one of the two just shows the other.
  output$combined_plot <- renderPlot({
    w_df <- wellness_raw()
    r_df <- rpe_raw()
    metric_col <- WELLNESS_METRICS[[input$wellness_metric]]

    wellness_z <- tibble(athlete = character(), z_wellness = numeric())
    if (nrow(w_df) > 0) {
      day_w <- w_df %>%
        filter(date == input$summary_date) %>%
        group_by(athlete) %>%
        summarise(value = dplyr::last(.data[[metric_col]]), .groups = "drop") %>%
        filter(!is.na(value))
      if (nrow(day_w) >= 2) {
        m <- mean(day_w$value); s <- sd(day_w$value)
        if (is.finite(s) && s > 0) {
          wellness_z <- day_w %>% mutate(z_wellness = (value - m) / s) %>% select(athlete, z_wellness)
        }
      }
    }

    load_z <- tibble(athlete = character(), z_load = numeric())
    if (nrow(r_df) > 0) {
      day_r <- r_df %>%
        filter(date == input$summary_date) %>%
        group_by(athlete) %>%
        summarise(value = sum(session_load, na.rm = TRUE), .groups = "drop") %>%
        filter(!is.na(value))
      if (nrow(day_r) >= 2) {
        m <- mean(day_r$value); s <- sd(day_r$value)
        if (is.finite(s) && s > 0) {
          load_z <- day_r %>% mutate(z_load = (value - m) / s) %>% select(athlete, z_load)
        }
      }
    }

    combined <- full_join(wellness_z, load_z, by = "athlete")
    validate(need(nrow(combined) > 0,
                  "No wellness or load responses for this date yet (or not enough athletes to compute a group Z-score)."))

    combined <- combined %>%
      arrange(athlete) %>%
      mutate(athlete = factor(athlete, levels = athlete))

    ggplot(combined, aes(x = athlete)) +
      annotate("rect", xmin = -Inf, xmax = Inf, ymin = -0.5, ymax = 0.5,
               fill = "grey70", alpha = 0.4) +
      geom_hline(yintercept = 0, color = "grey30", linewidth = 0.6) +
      geom_col(aes(y = z_load, fill = "Load"), width = 0.5, na.rm = TRUE) +
      geom_point(aes(y = z_wellness, color = "Wellness"), size = 4, na.rm = TRUE) +
      scale_fill_manual(name = NULL, values = c("Load" = "#5B8FD6")) +
      scale_color_manual(name = NULL, values = c("Wellness" = "#E8792A")) +
      labs(x = NULL, y = "Z Score",
           title = paste0(input$wellness_metric, " & Load vs Group - ", format(input$summary_date, "%d %b %Y")),
           caption = paste0("Bars = training load Z-score (higher = more load than the group). ",
                             "Dots = ", input$wellness_metric, " Z-score (Higher = better).")) +
      theme_minimal(base_size = 13) +
      theme(axis.text.x = element_text(angle = 45, hjust = 1),
            plot.title = element_text(face = "bold"),
            legend.position = "top",
            legend.title = element_blank())
  })
}

shinyApp(ui, server)
