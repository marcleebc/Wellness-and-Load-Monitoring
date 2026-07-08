# Squad Daily Summary (Shiny app)

Simple daily dashboard: each athlete's wellness (pick a metric from the dropdown)
and training load, both plotted against the squad average for the selected date.
Reads live from your two Google Sheets using a Google service account
(`gs_service_account.json` in this folder), so new form responses show up
automatically.

## Files

- `app.R` - the whole app (UI + server), single file by design.
- `gs_service_account.json` - the credential the app uses to read your sheets.
  Keep this private. Do not post it publicly or commit it to a public GitHub repo.

## Run it locally first (recommended before deploying)

1. Install R (https://cran.r-project.org) and RStudio if you don't have them.
2. Open `app.R` in RStudio.
3. In the R console, install the packages the app needs (one-time):

   ```r
   install.packages(c("shiny", "googlesheets4", "dplyr", "tidyr", "tibble", "ggplot2", "scales"))
   ```

4. Click "Run App" (top-right of the editor pane), or run:

   ```r
   shiny::runApp(".")
   ```

5. You should see the dashboard open. Since your athletes likely haven't
   submitted any real form responses yet, both charts will show a message
   like "No data yet for this date" instead of a plot -- that's expected,
   not a bug. Once responses come in for a given day, pick that date to see
   the charts populate.

If anything errors out, copy the red error text from the R console back to
me and I'll fix it. There's also a "Show diagnostics" button at the very
bottom of the app that reveals what was actually read from each sheet, any
read error, and the dates/athletes/load values it found - if a chart looks
wrong or empty, click that and send me what it says, that's usually faster
than digging through the R console.

**Note on testing:** I wrote and reviewed this code carefully, but the
sandbox I worked in couldn't install R or reach Google's servers (both are
blocked by its network policy), so I wasn't able to run the app myself
end-to-end. Please do the local run above before deploying, it only takes a
couple of minutes and confirms everything actually works with your live
data.

## Deploy to Posit Connect Cloud

Connect Cloud deploys from a GitHub repo, and its free tier only works with
**public** repos. Since `gs_service_account.json` is a real credential, it
must never be committed to that repo. `app.R` already handles this: it
reads the credential from the `GS_SERVICE_ACCOUNT_JSON` environment
variable if one is set, and only falls back to reading the local file if
not. `.gitignore` in this folder excludes `gs_service_account.json` (and
other R housekeeping files) so it can't be committed by accident.

Once the local run works (see above):

**1. Create the GitHub repo**

- Go to github.com -> New repository.
- Name it something like `squad-dashboard`. Leave it Public.
- Don't check "Add a README" or "Add .gitignore" - this folder already has
  its own files, and starting the GitHub repo empty avoids a merge
  conflict when you push.
- Click Create repository, then leave that page open - you'll need the
  repo URL it shows you (looks like `https://github.com/<you>/squad-dashboard.git`).

**2. Push this folder to it**

In RStudio: File -> New Project -> Existing Directory -> pick this
`squad_dashboard` folder. Then open a terminal (Tools -> Terminal -> New
Terminal in RStudio) and run:

```bash
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/<you>/squad-dashboard.git
git push -u origin main
```

(Replace the URL with your actual repo URL from step 1.)

Before pushing, double check the credential isn't included:

```bash
git status
```

`gs_service_account.json` should NOT appear in the list of files to be
committed (`.gitignore` should be keeping it out automatically). If you
see it listed, stop and let me know before pushing.

**3. Add the dependency manifest**

Connect Cloud needs a `manifest.json` telling it which R version and
packages to install. In the R console, from this project's folder:

```r
install.packages("rsconnect")
rsconnect::writeManifest()
```

Then commit and push that new file too:

```bash
git add manifest.json
git commit -m "Add manifest for Connect Cloud"
git push
```

**4. Publish on Connect Cloud**

1. Go to connect.posit.cloud and sign in (you can sign in with your
   GitHub account).
2. Authorize the Connect Cloud GitHub App if prompted, and grant it access
   to the `squad-dashboard` repo you just created.
3. Click the Publish button on your Home page.
4. Select Shiny.
5. Select the `squad-dashboard` repository, confirm the branch (`main`),
   and select `app.R` as the primary file.
6. Click "Advanced settings" -> "Add variable" under Configure variables.
7. Name: `GS_SERVICE_ACCOUNT_JSON`. Value: open `gs_service_account.json`
   in a text editor, select all, copy, and paste the entire contents in as
   the value.
8. Click Publish.

Connect Cloud will show build logs while it deploys. Once it finishes,
you'll get a shareable URL for the dashboard.

**5. Updating later**

Any time you change `app.R` (or I do), commit and push the change to
GitHub, then use the "republish" button on Connect Cloud's content page
for this app - it'll pick up the new code automatically.

## Alternative: shinyapps.io

If you'd rather not deal with GitHub at all, shinyapps.io is a simpler
option since it deploys straight from your local folder with no repo
involved (and the credential file just travels with the app bundle,
private by default). Steps:

1. Install the deployment package (one-time): `install.packages("rsconnect")`
2. Get your token: shinyapps.io -> your account -> Tokens -> "Show" -> "Show Secret".
3. In the R console, paste the 3-line snippet shinyapps.io gives you, it looks like:

   ```r
   rsconnect::setAccountInfo(name="<your-account-name>",
                             token="<your-token>",
                             secret="<your-secret>")
   ```

   (Run this yourself with your own token, I don't handle account tokens.)

4. Then deploy:

   ```r
   rsconnect::deployApp(".")
   ```

5. shinyapps.io will give you a URL like
   `https://<your-account-name>.shinyapps.io/squad_dashboard/`. That's the
   link you and your staff can bookmark.

Note: the app bundle uploaded to shinyapps.io includes the service account
key file, since the app needs it to run. shinyapps.io apps are private by
default (only accessible via the direct link), which is fine for this use
case, but don't make the app "public" in shinyapps.io's settings unless
you're comfortable with that.

## What's plotted

There are four charts, top to bottom:

- **Individual Wellness vs Group**: pick a metric from the dropdown
  (Fatigue, Stress, Sleep, Muscle Soreness, or Total Wellness Score). Each
  is on a 1-7 scale from the form (1 = Very very good, 7 = Very very Bad),
  so lower is better. Total Wellness Score is the average of the other
  four (the sheet's own "wellness" column is left blank, so the app
  computes this itself). Each athlete's value for the selected date is
  shown as a Z-score against that day's squad average - a value near 0 is
  normal, the shaded band marks +/- 0.5 SD, and a higher Z score means
  worse than the group (the scale runs good-to-bad).
- **Individual Load vs Group**: a plain bar chart of each athlete's session
  load (AU) for the selected date, with a dashed line marking that day's
  squad average. Session load is computed by the app itself as duration
  (minutes) x RPE, the standard session-RPE training load formula, since
  the RPE sheet doesn't have a pre-calculated load column.
- **Individual Wellness vs Load**: a combined view of the two above -
  wellness (dots) and load (bars), both as Z-scores against their own
  group, on one chart. Wellness uses whichever metric is picked in the
  same dropdown as the first chart. Since the two forms can have different
  responders on any given day, an athlete missing one of the two just
  shows the other (bar or dot alone, not both).
- **Weekly Load & Wellness**: a Monday-through-Sunday view for one week at
  a time. Load is bars, the chosen wellness metric is a dashed line with
  dots, both on the same chart. Pick the week from the "Week (starting
  Monday)" dropdown (each option is labeled by that week's Monday), pick
  the wellness metric from its own dropdown here, and optionally pick a
  single player - leave "All (group average)" selected to see the team's
  daily average instead. Wellness runs on a fixed 1-7 scale, shown on the
  right-hand axis, rescaled to overlay on the load bars' left-hand axis.

## Changing the roster or metrics

Both charts pull the athlete list directly from whoever has submitted a
form response, there's no separate roster file to maintain. The wellness
sheet's numeric columns (I: fatigue, J: stress, K: sleep, L: soreness) are
converted from the text answers using formulas already in the sheet - if
you add new wellness questions to the Google Form later, add a matching
column to the sheet and a corresponding entry to `WELLNESS_COLS` and
`WELLNESS_METRICS` near the top of `app.R` (in the same column position as
it appears in the sheet).
