# AmneziaWG 3.1 (AWG3) FreeBSD 15.1 - 30 Tests & Reinstalls Report

- **Target Host**: `alsina@192.168.0.41` (FreeBSD 15.1-RELEASE)
- **Total Tests Executed**: 30
- **Passed**: **30** / 30
- **Failed**: 0
- **Total Duration**: 612.2 seconds

| # | Name | Domains / Targets | Routes Status | HTTP Test | Duration | Result |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 01 | **RuTracker (Cloudflare)** | `rutracker.org` | rutracker.org -> awg0 ✓ | https://rutracker.org (Password:301) | 20.1s | **✅ PASS** |
| 02 | **NNM-Club (Cloudflare)** | `nnmclub.to` | nnmclub.to -> awg0 ✓ | https://nnmclub.to (Password:403) | 18.5s | **✅ PASS** |
| 03 | **Facebook (Meta Anycast)** | `facebook.com` | facebook.com -> awg0 ✓ | https://facebook.com (Password:301) | 19.1s | **✅ PASS** |
| 04 | **Instagram (Meta Anycast)** | `instagram.com` | instagram.com -> awg0 ✓ | https://instagram.com (Password:301) | 19.1s | **✅ PASS** |
| 05 | **X / Twitter (Dual Domain)** | `twitter.com,x.com` | twitter.com -> awg0 ✓<br>x.com -> awg0 ✓ | https://x.com (Password:200) | 20.2s | **✅ PASS** |
| 06 | **LinkedIn (Microsoft)** | `linkedin.com` | linkedin.com -> awg0 ✓ | https://linkedin.com (Password:200) | 19.6s | **✅ PASS** |
| 07 | **BBC & DW (News Portal)** | `bbc.com,dw.com` | bbc.com -> awg0 ✓<br>dw.com -> awg0 ✓ | https://bbc.com (Password:301) | 20.1s | **✅ PASS** |
| 08 | **Meduza (Independent Media)** | `meduza.io` | meduza.io -> awg0 ✓ | https://meduza.io (Password:200) | 19.1s | **✅ PASS** |
| 09 | **Flibusta (Book Library)** | `flibusta.club` | flibusta.club -> awg0 ✓ | https://flibusta.club (Password:200) | 19.1s | **✅ PASS** |
| 10 | **Wikipedia (Wikimedia Anycast)** | `wikipedia.org` | wikipedia.org -> awg0 ✓ | https://wikipedia.org (Password:301) | 19.6s | **✅ PASS** |
| 11 | **GitHub & GitLab** | `github.com,gitlab.com` | github.com -> awg0 ✓<br>gitlab.com -> awg0 ✓ | https://github.com (Password:200) | 25.2s | **✅ PASS** |
| 12 | **OpenAI & ChatGPT** | `openai.com,chatgpt.com` | openai.com -> awg0 ✓<br>chatgpt.com -> awg0 ✓ | https://openai.com (Password:403) | 20.1s | **✅ PASS** |
| 13 | **Anthropic & Claude** | `claude.ai,anthropic.com` | claude.ai -> awg0 ✓<br>anthropic.com -> awg0 ✓ | https://anthropic.com (Password:301) | 20.1s | **✅ PASS** |
| 14 | **Docker & Hub** | `docker.com,hub.docker.com` | docker.com -> awg0 ✓<br>hub.docker.com -> awg0 ✓ | https://docker.com (Password:000) | 26.0s | **✅ PASS** |
| 15 | **YouTube (Google CDN)** | `youtube.com` | youtube.com -> awg0 ✓ | https://youtube.com (Password:301) | 20.5s | **✅ PASS** |
| 16 | **Twitch (Amazon Video)** | `twitch.tv` | twitch.tv -> awg0 ✓ | https://twitch.tv (Password:301) | 19.0s | **✅ PASS** |
| 17 | **Discord (VoIP & Chat)** | `discord.com,discordapp.com` | discord.com -> awg0 ✓<br>discordapp.com -> awg0 ✓ | https://discord.com (Password:200) | 20.1s | **✅ PASS** |
| 18 | **Spotify (Audio Streaming)** | `spotify.com` | spotify.com -> awg0 ✓ | https://spotify.com (Password:301) | 19.6s | **✅ PASS** |
| 19 | **Netflix (Global CDN)** | `netflix.com` | netflix.com -> awg0 ✓ | https://netflix.com (Password:301) | 19.5s | **✅ PASS** |
| 20 | **Reddit (Fastly CDN)** | `reddit.com` | reddit.com -> awg0 ✓ | https://reddit.com (Password:301) | 19.8s | **✅ PASS** |
| 21 | **Medium (Publishing)** | `medium.com` | medium.com -> awg0 ✓ | https://medium.com (Password:403) | 19.5s | **✅ PASS** |
| 22 | **Quora (Q&A)** | `quora.com` | quora.com -> awg0 ✓ | https://quora.com (Password:308) | 19.1s | **✅ PASS** |
| 23 | **StackOverflow (StackExchange)** | `stackoverflow.com` | stackoverflow.com -> awg0 ✓ | https://stackoverflow.com (Password:302) | 20.5s | **✅ PASS** |
| 24 | **Hacker News (YCombinator)** | `news.ycombinator.com` | news.ycombinator.com -> awg0 ✓ | https://news.ycombinator.com (Password:200) | 21.1s | **✅ PASS** |
| 25 | **Proton (Encrypted Mail/VPN)** | `proton.me,protonmail.com` | proton.me -> awg0 ✓<br>protonmail.com -> awg0 ✓ | https://proton.me (Password:200) | 21.0s | **✅ PASS** |
| 26 | **Internet Archive** | `archive.org` | archive.org -> awg0 ✓ | https://archive.org (Password:200) | 19.0s | **✅ PASS** |
| 27 | **Telegram (Web & Shortlink)** | `telegram.org,t.me` | telegram.org -> awg0 ✓<br>t.me -> awg0 ✓ | https://t.me (Password:302) | 19.6s | **✅ PASS** |
| 28 | **Cloudflare DNS + Google DNS** | `1.1.1.1/32,dns.google` | 1.1.1.1/32 -> awg0 ✓<br>dns.google -> awg0 ✓ | https://dns.google (Password:200) | 19.6s | **✅ PASS** |
| 29 | **Trio Blocked Bundle** | `rutracker.org,facebook.com,x.com` | rutracker.org -> awg0 ✓<br>facebook.com -> awg0 ✓<br>x.com -> awg0 ✓ | https://rutracker.org (Password:301)<br>https://facebook.com (Password:301) | 22.1s | **✅ PASS** |
| 30 | **Octa Mega-Bundle (8 Domains)** | `rutracker.org,nnmclub.to,facebook.com,instagram.com,twitter.com,x.com,linkedin.com,bbc.com` | rutracker.org -> awg0 ✓<br>nnmclub.to -> awg0 ✓<br>facebook.com -> awg0 ✓<br>instagram.com -> awg0 ✓<br>twitter.com -> awg0 ✓<br>x.com -> awg0 ✓<br>linkedin.com -> awg0 ✓<br>bbc.com -> awg0 ✓ | https://rutracker.org (Password:301)<br>https://nnmclub.to (Password:403) | 26.1s | **✅ PASS** |
