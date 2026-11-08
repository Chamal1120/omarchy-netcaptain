# Network Usage

An Omarchy shell bar widget that tracks how much data you download and upload,
per day, per month, and per connection.

The bar shows only an icon. Click it for the active connection, its live
rate, today's totals and data limits. A **History** row below them (or `h`)
expands the rest:

- a history chart of the last 14 days or 12 months, for this network or all of them;
  with a limit set, each day or month is one bar filled to its share of the daily or
  monthly limit (urgent from 90%). Without a limit, or under *All*, the chart shows
  only labels, and hovering or clicking a day still shows its usage
- the per-connection breakdown for whichever day or month is selected

Click any network in that list to show its own history in the chart and totals,
even when you are not connected to it. It gets its own chip next to
*This network* and *All*; click it again (or pick another chip) to go back.
The Months view lists every network used in the last year.

Middle-click the icon to sample immediately.

## Data limits

Each network can have a daily and a monthly limit, counting download and
upload together the way carriers meter data. Set them in the popup under
**Data limits** (click *Set limits*, or press `l`). Type amounts like `2 GB`,
`1.5 GB` or `500 MB`; a bare number means GB, and an empty field means no
limit. The section follows the network the chart is showing, so you can set
limits for a network you are not connected to.

You get one notification when a day's or month's usage reaches 90% of its
limit and another when it reaches the limit. They come from the background
sampler, so the popup does not need to be open. Changing a limit re-arms its
warnings against the new value.

The monthly limit runs over the network's billing cycle. Set **Billing day** in
the editor to the day your plan resets (1–31, default 1); the row then reads
*This cycle · 15 Nov – 14 Dec*. In a month too short for the day, the cycle
starts on the month's last day. Moving the billing day re-arms the monthly
warnings. For such a network the history chart's Months view becomes **Cycles**: the
last 12 billing cycles, each measured against the monthly limit, with the
connections list covering the selected cycle's dates. Networks billed on the 1st
and the *All* view use calendar months.

Keys in the popup: `←`/`→` move along the chart, `d` days, `m` months,
`a` cycle the chips, `l` edit limits, `↑`/`↓` then `Enter` pick a network, `r` refresh, `Tab` next panel, `h` show or hide history, `Esc` close. The chart keys open History if it is closed.

## Install

```bash
omarchy plugin add https://github.com/Chamal1120/omarchy-netcaptain.git --enable
```

Update it later with `omarchy plugin update chamal.netusage`. It needs Python 3
and NetworkManager, both standard on Omarchy.

## How it measures

`netusage.py` reads the kernel byte counters in `/sys/class/net/*/statistics`
for hardware interfaces (bridges, Docker, veths and VPN tunnels are skipped, as
their traffic is already counted on the physical link) and adds the change
since the last sample to the connection NetworkManager reports on that
interface. Limits and the warnings already sent are kept in the same database. Data is stored in SQLite at
`~/.local/share/omarchy-netusage/usage.db`.

Sampling runs only while the shell is running. Traffic between samples on the
same boot is still caught on the next sample. Traffic from a boot that ended
before the shell sampled it is lost. Reboots and counter resets are handled.

It makes no network requests and needs only Python 3's standard library and
`nmcli` (for connection names; without it, interface names are used).

## Settings

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `60` | Seconds between samples (10–3600) |
| `notifyLimits` | `true` | Notify at 90% and when a data limit is reached |

```json
{ "id": "chamal.netusage", "refreshIntervalSec": 60 }
```

## Development

```bash
python3 -I -m unittest discover -s tests
node --test tests
omarchy plugin validate .
```
