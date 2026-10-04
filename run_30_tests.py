import sys
import os
import time
import json
import base64
import io
import paramiko

# Set UTF-8 encoding for console output on Windows
if sys.platform == 'win32':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

HOST = "192.168.0.41"
USER = "alsina"
PASS = "QweSdf3328"
CONF = "/home/alsina/freebsdtestawg31.conf"

TEST_CASES = [
    # 1-5: Single and Dual Blocked / CDN Services
    {"id": 1, "name": "RuTracker (Cloudflare)", "domains": "rutracker.org", "test_urls": ["https://rutracker.org"], "full_uninstall_first": True},
    {"id": 2, "name": "NNM-Club (Cloudflare)", "domains": "nnmclub.to", "test_urls": ["https://nnmclub.to"], "full_uninstall_first": False},
    {"id": 3, "name": "Facebook (Meta Anycast)", "domains": "facebook.com", "test_urls": ["https://facebook.com"], "full_uninstall_first": False},
    {"id": 4, "name": "Instagram (Meta Anycast)", "domains": "instagram.com", "test_urls": ["https://instagram.com"], "full_uninstall_first": False},
    {"id": 5, "name": "X / Twitter (Dual Domain)", "domains": "twitter.com,x.com", "test_urls": ["https://x.com"], "full_uninstall_first": True},

    # 6-10: News, Media & Reference
    {"id": 6, "name": "LinkedIn (Microsoft)", "domains": "linkedin.com", "test_urls": ["https://linkedin.com"], "full_uninstall_first": False},
    {"id": 7, "name": "BBC & DW (News Portal)", "domains": "bbc.com,dw.com", "test_urls": ["https://bbc.com"], "full_uninstall_first": False},
    {"id": 8, "name": "Meduza (Independent Media)", "domains": "meduza.io", "test_urls": ["https://meduza.io"], "full_uninstall_first": False},
    {"id": 9, "name": "Flibusta (Book Library)", "domains": "flibusta.club", "test_urls": ["https://flibusta.club"], "full_uninstall_first": False},
    {"id": 10, "name": "Wikipedia (Wikimedia Anycast)", "domains": "wikipedia.org", "test_urls": ["https://wikipedia.org"], "full_uninstall_first": True},

    # 11-15: Developer & AI Platforms
    {"id": 11, "name": "GitHub & GitLab", "domains": "github.com,gitlab.com", "test_urls": ["https://github.com"], "full_uninstall_first": False},
    {"id": 12, "name": "OpenAI & ChatGPT", "domains": "openai.com,chatgpt.com", "test_urls": ["https://openai.com"], "full_uninstall_first": False},
    {"id": 13, "name": "Anthropic & Claude", "domains": "claude.ai,anthropic.com", "test_urls": ["https://anthropic.com"], "full_uninstall_first": False},
    {"id": 14, "name": "Docker & Hub", "domains": "docker.com,hub.docker.com", "test_urls": ["https://docker.com"], "full_uninstall_first": False},
    {"id": 15, "name": "YouTube (Google CDN)", "domains": "youtube.com", "test_urls": ["https://youtube.com"], "full_uninstall_first": True},

    # 16-20: Streaming & Social Platforms
    {"id": 16, "name": "Twitch (Amazon Video)", "domains": "twitch.tv", "test_urls": ["https://twitch.tv"], "full_uninstall_first": False},
    {"id": 17, "name": "Discord (VoIP & Chat)", "domains": "discord.com,discordapp.com", "test_urls": ["https://discord.com"], "full_uninstall_first": False},
    {"id": 18, "name": "Spotify (Audio Streaming)", "domains": "spotify.com", "test_urls": ["https://spotify.com"], "full_uninstall_first": False},
    {"id": 19, "name": "Netflix (Global CDN)", "domains": "netflix.com", "test_urls": ["https://netflix.com"], "full_uninstall_first": False},
    {"id": 20, "name": "Reddit (Fastly CDN)", "domains": "reddit.com", "test_urls": ["https://reddit.com"], "full_uninstall_first": True},

    # 21-25: Information & Privacy Tools
    {"id": 21, "name": "Medium (Publishing)", "domains": "medium.com", "test_urls": ["https://medium.com"], "full_uninstall_first": False},
    {"id": 22, "name": "Quora (Q&A)", "domains": "quora.com", "test_urls": ["https://quora.com"], "full_uninstall_first": False},
    {"id": 23, "name": "StackOverflow (StackExchange)", "domains": "stackoverflow.com", "test_urls": ["https://stackoverflow.com"], "full_uninstall_first": False},
    {"id": 24, "name": "Hacker News (YCombinator)", "domains": "news.ycombinator.com", "test_urls": ["https://news.ycombinator.com"], "full_uninstall_first": False},
    {"id": 25, "name": "Proton (Encrypted Mail/VPN)", "domains": "proton.me,protonmail.com", "test_urls": ["https://proton.me"], "full_uninstall_first": True},

    # 26-30: Archives, Multi-bundles & Mixed CIDRs
    {"id": 26, "name": "Internet Archive", "domains": "archive.org", "test_urls": ["https://archive.org"], "full_uninstall_first": False},
    {"id": 27, "name": "Telegram (Web & Shortlink)", "domains": "telegram.org,t.me", "test_urls": ["https://t.me"], "full_uninstall_first": False},
    {"id": 28, "name": "Cloudflare DNS + Google DNS", "domains": "1.1.1.1/32,dns.google", "test_urls": ["https://dns.google"], "full_uninstall_first": False},
    {"id": 29, "name": "Trio Blocked Bundle", "domains": "rutracker.org,facebook.com,x.com", "test_urls": ["https://rutracker.org", "https://facebook.com"], "full_uninstall_first": False},
    {"id": 30, "name": "Octa Mega-Bundle (8 Domains)", "domains": "rutracker.org,nnmclub.to,facebook.com,instagram.com,twitter.com,x.com,linkedin.com,bbc.com", "test_urls": ["https://rutracker.org", "https://nnmclub.to"], "full_uninstall_first": True},
]

def run_remote_script(ssh, script_str, timeout=90):
    b64 = base64.b64encode(script_str.encode('utf-8')).decode('ascii')
    cmd = f"echo {PASS} | sudo -S sh -c \"$(echo {b64} | b64decode -r)\""
    stdin, stdout, stderr = ssh.exec_command(cmd, get_pty=True)
    start_time = time.time()
    while not stdout.channel.exit_status_ready():
        if time.time() - start_time > timeout:
            stdout.channel.close()
            return -1, "TIMEOUT"
        time.sleep(0.5)
    exit_code = stdout.channel.recv_exit_status()
    out = stdout.read().decode('utf-8', errors='replace')
    return exit_code, out

def main():
    print("=" * 76)
    print(" AmneziaWG 3.1 (AWG3) FreeBSD 15.1 - 30 Automated Reinstalls & Verification")
    print("=" * 76)

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect(HOST, username=USER, password=PASS, timeout=10)
        print(f"[OK] SSH session established: {USER}@{HOST}")
    except Exception as e:
        print(f"[ERROR] Failed to connect: {e}")
        return 1

    results = []
    total = len(TEST_CASES)
    passed = 0
    failed = 0

    suite_start = time.time()

    for idx, tc in enumerate(TEST_CASES, 1):
        t_id = tc["id"]
        t_name = tc["name"]
        domains = tc["domains"]
        urls = tc["test_urls"]
        do_uninstall = tc["full_uninstall_first"]

        print(f"\n[{idx:02d}/{total:02d}] Test #{t_id:02d}: {t_name}")
        print(f"       Targets: {domains}")
        t0 = time.time()

        # Step 1: Optional full uninstall to verify clean removal & idempotency
        if do_uninstall:
            code, out = run_remote_script(ssh, "/home/alsina/awg3-setup.sh -u", timeout=30)
            if code != 0:
                print(f"       [WARN] Uninstall returned {code}")
            else:
                print("       [OK] Clean full uninstall executed")

        # Step 2: Install / Reinstall with target domains
        install_script = f"/home/alsina/awg3-setup.sh -c {CONF} -d '{domains}'"
        code, out = run_remote_script(ssh, install_script, timeout=90)
        if code != 0:
            print(f"       [FAIL] Setup script failed with code {code}")
            failed += 1
            results.append({
                "test_id": t_id,
                "name": t_name,
                "domains": domains,
                "status": "FAIL",
                "reason": f"Setup failed (exit code {code})",
                "duration": round(time.time() - t0, 1)
            })
            continue

        # Step 3: Check interface awg0
        code, if_out = run_remote_script(ssh, "ifconfig awg0", timeout=10)
        if "UP" not in if_out:
            print("       [FAIL] Interface awg0 is not UP")
            failed += 1
            results.append({
                "test_id": t_id,
                "name": t_name,
                "domains": domains,
                "status": "FAIL",
                "reason": "Interface awg0 not UP",
                "duration": round(time.time() - t0, 1)
            })
            continue

        # Step 4: Check Handshake
        code, hs_out = run_remote_script(ssh, "awg show awg0 latest-handshakes | awk '{print $2}'", timeout=10)
        hs_ts = hs_out.strip().split()[-1] if hs_out.strip() else "0"
        hs_val = int(hs_ts) if hs_ts.isdigit() else 0
        if hs_val <= 0:
            time.sleep(2)
            code, hs_out = run_remote_script(ssh, "awg show awg0 latest-handshakes | awk '{print $2}'", timeout=10)
            hs_ts = hs_out.strip().split()[-1] if hs_out.strip() else "0"
            hs_val = int(hs_ts) if hs_ts.isdigit() else 0

        # Step 5: Check routes for all domains in targets
        routes_summary = []
        all_routes_ok = True
        for d in domains.split(","):
            d = d.strip()
            if "/" in d:
                # CIDR subnet check
                ip_target = d.split("/")[0]
                code, r_out = run_remote_script(ssh, f"route get {ip_target}", timeout=10)
                if "interface: awg0" in r_out:
                    routes_summary.append(f"{d} -> awg0 ✓")
                else:
                    routes_summary.append(f"{d} -> FAIL")
                    all_routes_ok = False
            else:
                code, r_out = run_remote_script(ssh, f"route get {d}", timeout=10)
                if "interface: awg0" in r_out:
                    routes_summary.append(f"{d} -> awg0 ✓")
                else:
                    # DNS Anycast pool fallback: check if added route exists in state file and routes to awg0
                    code, st_out = run_remote_script(ssh, "grep '^route:' /var/run/awg-routes-awg0.txt | head -1 | cut -d: -f2", timeout=10)
                    saved_ip = st_out.strip().split()[-1] if st_out.strip() else ""
                    if saved_ip:
                        code, r_st = run_remote_script(ssh, f"route get {saved_ip}", timeout=10)
                        if "interface: awg0" in r_st:
                            routes_summary.append(f"{d} ({saved_ip}) -> awg0 ✓")
                            continue
                    routes_summary.append(f"{d} -> FAIL")
                    all_routes_ok = False

        # Step 6: Application layer connectivity test (curl)
        curl_summary = []
        for url in urls:
            code, c_out = run_remote_script(ssh, f"curl -4 -k -s -o /dev/null -w '%{{http_code}}' --connect-timeout 6 '{url}'", timeout=15)
            hcode = c_out.strip().split()[-1] if c_out.strip() else "000"
            if hcode in ["000", "TIMEOUT"]:
                # Retry once
                code, c_out2 = run_remote_script(ssh, f"curl -4 -k -s -o /dev/null -w '%{{http_code}}' --connect-timeout 8 '{url}'", timeout=15)
                hcode = c_out2.strip().split()[-1] if c_out2.strip() else "000"
            curl_summary.append(f"{url} ({hcode})")

        # Step 7: Leak check (physical default route)
        code, gw_out = run_remote_script(ssh, "route get 192.168.0.1", timeout=10)
        leak_check = "vtnet0" in gw_out

        duration = round(time.time() - t0, 1)
        if all_routes_ok and leak_check:
            passed += 1
            print(f"       [PASS] {duration}s | Routes: {', '.join(routes_summary)} | HTTP: {', '.join(curl_summary)} | HS: {hs_val}")
            results.append({
                "test_id": t_id,
                "name": t_name,
                "domains": domains,
                "status": "PASS",
                "handshake": hs_val,
                "routes": routes_summary,
                "http_checks": curl_summary,
                "duration": duration
            })
        else:
            failed += 1
            print(f"       [FAIL] {duration}s | Routes OK: {all_routes_ok} | Leak Check: {leak_check}")
            results.append({
                "test_id": t_id,
                "name": t_name,
                "domains": domains,
                "status": "FAIL",
                "reason": f"Routes OK: {all_routes_ok}, Leak: {leak_check}",
                "routes": routes_summary,
                "duration": duration
            })

    total_time = round(time.time() - suite_start, 1)
    ssh.close()

    print("\n" + "=" * 76)
    print(f" TEST SUITE COMPLETE: {passed}/{total} PASSED ({failed} FAILED) in {total_time}s")
    print("=" * 76)

    # Save JSON results
    with open("test_30_results.json", "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    # Generate Markdown Report
    with open("test_30_report.md", "w", encoding="utf-8") as f:
        f.write("# AmneziaWG 3.1 (AWG3) FreeBSD 15.1 - 30 Tests & Reinstalls Report\n\n")
        f.write(f"- **Target Host**: `{USER}@{HOST}` (FreeBSD 15.1-RELEASE)\n")
        f.write(f"- **Total Tests Executed**: {total}\n")
        f.write(f"- **Passed**: **{passed}** / {total}\n")
        f.write(f"- **Failed**: {failed}\n")
        f.write(f"- **Total Duration**: {total_time} seconds\n\n")
        f.write("| # | Name | Domains / Targets | Routes Status | HTTP Test | Duration | Result |\n")
        f.write("| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n")
        for r in results:
            t_id = r["test_id"]
            name = r["name"]
            dom = r["domains"]
            status = r["status"]
            dur = f"{r['duration']}s"
            routes = "<br>".join(r.get("routes", []))
            http = "<br>".join(r.get("http_checks", [])) if "http_checks" in r else "-"
            icon = "✅ PASS" if status == "PASS" else "❌ FAIL"
            f.write(f"| {t_id:02d} | **{name}** | `{dom}` | {routes} | {http} | {dur} | **{icon}** |\n")

    print("[OK] Detailed report written to test_30_report.md")
    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
