#!/usr/bin/env python3
# Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE_HW file.

"""SDK unit-test dashboard collector: one aggregate record per test round,
plus OBS daily-file archiving (--archive).

Contract schema (vendored, keep in sync with CPF-Flutter/tests docs):
ci/resources/framework-data.schema.json

The 'Collect Dashboard Data' test step runs this script once after the
shard step of every ci/test.sh round; a round is the execution logs the
shards leave under <unit_tests_logs> (dart-test machine reports
reports/<shard>/metrics_*.json, one JSON Lines file per `dart test`
invocation):

  round aggregation -> one record -> validation (zero write on failure)
    -> <unit_tests_logs>/framework-data.json
       + per-round copy dashboard/framework-data_<round_id>.json
    -> --archive then merges every pending per-round copy into the OBS
       daily file cloud_test://flutter/daily_data/<yyyymmdd>/
       framework-data.json via the cipd `archive` CLI: session-key
       idempotent merge (sourceRunId/runnerModule/buildHost, same key
       family as the CPF-Flutter/tests collector so both record families
       merge alike) with read-back verification; archived files move to
       dashboard/uploaded/, invalid ones to dashboard/rejected/. The
       CLI's $HOME obsutil config is self-bootstrapped with a best-effort
       `archive init` and, when this run created it, removed again with
       `archive uninstall` after the uploads.

The round window is --round-start/--round-end when given, else derived
from the metric files themselves (first invocation start .. last event
end), which matches a fresh per-round log dir.

Both phases never fail the test pipeline: errors print as notes/WARN lines
and the exit code is non-zero only so the caller can surface a warning.
"""

import argparse
import json
import os
import platform
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import OrderedDict
from datetime import datetime, timedelta, timezone
from pathlib import Path

FLUTTER_ROOT = Path(__file__).resolve().parents[2]
TZ = timezone(timedelta(hours=8))  # record timestamps use +08 wall clock
MB = 1048576
MODULE = 'FlutterSdkUnitTest'
SOURCE_REPO_URL = 'https://gitcode.com/CPF-Flutter/flutter_flutter'
PR_URL_TEMPLATE = 'https://gitcode.com/CPF-Flutter/flutter_flutter/pull/{}'
DEFAULT_BUILD_COMMAND = 'bash third_party/flutter_flutter/ci/test.sh'
# Host engine artifacts the tests execute on (flutter_tester host runtime);
# no device HAP is built, so the device-side size metric does not apply.
ENGINE_ARTIFACTS_REL = Path('bin/cache/artifacts/engine/linux-x64')

RECORD_ID_RE = re.compile(r'^(\S+)-(\d{8})-(\d{3})$')
METRICS_NAME_RE = re.compile(r'^metrics_(\d{13,19})\.json$')
PR_NO_RE = re.compile(r'merge_requests/(\d+)')
REASON_MAX = 480

# dart test machine-report protocol (protocolVersion 0.1.1): every suite has
# a hidden "loading" wrapper; wrappers and hidden lifecycle cases are
# excluded from counts, EXCEPT a wrapper whose suite failed to load (reports
# hidden=false result=error) which is a real counted failure. skip-metadata
# cases count as skippedCases. Started cases with no completion (crashed
# runner) surface via unfinishedCases and are not counted in totalCases.
# metrics file names carry the invocation start time as epoch microseconds.


def now_iso():
    return datetime.now(TZ).isoformat()


def epoch_to_iso(epoch_secs):
    return datetime.fromtimestamp(epoch_secs, TZ).isoformat()


def duration_text(seconds):
    """Platform durationText format (Chinese h/m/s units), zero units omitted."""
    h, rest = divmod(int(seconds), 3600)
    m, s = divmod(rest, 60)
    if h:
        return '%d时%02d分%02d秒' % (h, m, s)
    if m:
        return '%d分%02d秒' % (m, s)
    return '%d秒' % s


def round_id_for(epoch_secs):
    """Stable per-round identity from the round start (+08 wall clock)."""
    return 'unit_tests_' + datetime.fromtimestamp(
        epoch_secs, TZ).strftime('%Y%m%d_%H%M%S')


def date_key_for(epoch_secs):
    return datetime.fromtimestamp(epoch_secs, TZ).strftime('%Y%m%d')


# ---------------------------------------------------------------------------
# Per-file parsing
# ---------------------------------------------------------------------------

class FileStats(object):
    def __init__(self, shard, start_epoch):
        self.shard = shard
        self.start_epoch = start_epoch
        self.end_epoch = start_epoch
        self.suites = 0
        self.started = 0
        self.started_all = 0
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.finished = 0
        self.unfinished = 0
        self.done_success = None
        self.failures = []
        self.parse_errors = 0


def _handle_test_done(stats, started, doned, errors_by_test, tid, ev):
    """Count one finished visible case; classify its result."""
    doned.add(tid)
    info = started.get(tid)
    if info is None or ev.get('hidden'):
        return  # never-started or hidden wrapper/lifecycle case
    stats.finished += 1
    result = ev.get('result')
    if result == 'failure' or result == 'error':
        stats.failed += 1
        reason = (errors_by_test.get(tid) or '').strip()
        name = info['name']
        if name.startswith('loading '):
            # Failed suite load: surface the file, not the wrapper.
            name = name[len('loading '):].strip().strip('"')
            name = name.rsplit('/', 1)[-1]
        stats.failures.append({
            'name': name,
            'suite': info['suite'],
            'reason': reason,
        })
    elif result == 'success' and info['skip']:
        stats.skipped += 1
    elif result == 'success':
        stats.passed += 1
    else:
        # Unknown result value: count as failed, keep visible.
        stats.failed += 1
        stats.failures.append({
            'name': info['name'],
            'suite': info['suite'],
            'reason': 'unrecognized testDone result: %r' % result,
        })


def _handle_metric_event(stats, started, doned, errors_by_test,
                         suite_paths, ev):
    """Update per-file state from one dart-test protocol event."""
    etype = ev.get('type')
    rel_ms = ev.get('time')
    if isinstance(rel_ms, (int, float)):
        stats.end_epoch = max(
            stats.end_epoch, stats.start_epoch + rel_ms / 1000.0)
    if etype == 'suite':
        suite = ev.get('suite') or {}
        suite_paths[suite.get('id')] = suite.get('path') or ''
        stats.suites += 1
    elif etype == 'testStart':
        test = ev.get('test') or {}
        started[test.get('id')] = {
            'name': test.get('name') or '',
            'suite': suite_paths.get(test.get('suiteID'), ''),
            'skip': bool((test.get('metadata') or {}).get('skip')),
        }
        stats.started_all += 1
        if not (test.get('name') or '').startswith('loading '):
            stats.started += 1
    elif etype == 'error':
        errors_by_test[ev.get('testID')] = ev.get('error') or ''
    elif etype == 'testDone':
        _handle_test_done(
            stats, started, doned, errors_by_test, ev.get('testID'), ev)
    elif etype == 'done':
        stats.done_success = bool(ev.get('success'))


def parse_metric_file(path, shard):
    """Parse one dart-test machine report (JSON Lines) into case stats."""
    m = METRICS_NAME_RE.match(path.name)
    start_epoch = int(m.group(1)) / 1e6 if m else 0
    stats = FileStats(shard, start_epoch)
    started = {}
    doned = set()
    errors_by_test = {}
    suite_paths = {}
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                stats.parse_errors += 1
                continue
            _handle_metric_event(
                stats, started, doned, errors_by_test, suite_paths, ev)
    stats.unfinished = sum(1 for tid in started if tid not in doned)
    return stats


# ---------------------------------------------------------------------------
# Round aggregation
# ---------------------------------------------------------------------------

def scan_metric_files(log_dir, round_start_epoch):
    """All metrics_*.json under reports/*, optionally scoped to one round.

    Returns (files, notes): files = [(path, shard_label)] sorted by shard.
    """
    notes = []
    reports_dir = Path(log_dir) / 'reports'
    if not reports_dir.is_dir():
        return [], ['skip: no reports dir under %s' % log_dir]
    files = []
    for shard_dir in sorted(p for p in reports_dir.iterdir() if p.is_dir()):
        for path in sorted(shard_dir.glob('metrics_*.json')):
            files.append((path, shard_dir.name))
    if round_start_epoch is None:
        if files:
            notes.append(
                'info: no round window given, scanning ALL %d metric file(s) '
                'in %s (a persistent log dir would fold older rounds in)' % (
                    len(files), reports_dir))
        return files, notes
    kept = []
    for path, shard in files:
        m = METRICS_NAME_RE.match(path.name)
        file_epoch = int(m.group(1)) / 1e6 if m else 0
        if file_epoch >= round_start_epoch:
            kept.append((path, shard))
    dropped = len(files) - len(kept)
    if dropped:
        notes.append('info: round window dropped %d older metric file(s)'
                     % dropped)
    return kept, notes


def collect_round(files):
    """Aggregate per-file stats into round totals + per-shard stats."""
    shards = OrderedDict()
    totals = {
        'files': 0, 'suites': 0, 'started': 0, 'passed': 0, 'failed': 0,
        'skipped': 0, 'finished': 0, 'unfinished': 0,
        'first_start': None, 'last_end': None,
        'parse_errors': 0,
    }
    for path, shard in files:
        stats = parse_metric_file(path, shard)
        totals['files'] += 1
        totals['suites'] += stats.suites
        totals['started'] += stats.started
        totals['passed'] += stats.passed
        totals['failed'] += stats.failed
        totals['skipped'] += stats.skipped
        totals['finished'] += stats.finished
        totals['unfinished'] += stats.unfinished
        totals['parse_errors'] += stats.parse_errors
        if stats.start_epoch and (totals['first_start'] is None or
                                  stats.start_epoch < totals['first_start']):
            totals['first_start'] = stats.start_epoch
        if stats.end_epoch and (totals['last_end'] is None or
                                stats.end_epoch > totals['last_end']):
            totals['last_end'] = stats.end_epoch
        agg = shards.setdefault(shard, {
            'label': shard, 'files': 0, 'suites': 0, 'passed': 0,
            'failed': 0, 'skipped': 0, 'run_failed': False, 'failures': [],
        })
        agg['files'] += 1
        agg['suites'] += stats.suites
        agg['passed'] += stats.passed
        agg['failed'] += stats.failed
        agg['skipped'] += stats.skipped
        agg['failures'].extend(stats.failures)
        if stats.done_success is not True:
            agg['run_failed'] = True  # failed run or no 'done' at all
    for agg in shards.values():
        agg['total'] = agg['passed'] + agg['failed'] + agg['skipped']
    return shards, totals


# ---------------------------------------------------------------------------
# Environment facts (git identity, engine artifacts, PR)
# ---------------------------------------------------------------------------

def git_identity():
    branch = commit = ''
    for args, setter in (
        (['rev-parse', '--abbrev-ref', 'HEAD'], 'branch'),
        (['rev-parse', 'HEAD'], 'commit'),
    ):
        try:
            res = subprocess.run(
                ['git', '-C', str(FLUTTER_ROOT)] + args,
                capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            break
        if res.returncode == 0 and res.stdout.strip():
            if setter == 'branch':
                branch = res.stdout.strip()
            else:
                commit = res.stdout.strip()
    if not branch or branch == 'HEAD':
        # Detached HEAD (how PR pipelines check out) carries no branch
        # name; fall back to TARGET_BRANCH, the same source runner.py
        # sets from config precisely because git is unreliable there.
        branch = os.environ.get('TARGET_BRANCH', 'unknown')
    return branch, commit


def measure_engine_artifacts():
    """Total bytes of the host engine artifacts dir, or None if missing."""
    root = FLUTTER_ROOT / ENGINE_ARTIFACTS_REL
    if not root.is_dir():
        return None
    total = 0
    for dirpath, _dirnames, filenames in os.walk(str(root)):
        for name in filenames:
            try:
                total += os.stat(os.path.join(dirpath, name)).st_size
            except OSError:
                pass
    return total


def dart_sdk_version():
    version_file = FLUTTER_ROOT / 'bin/cache/dart-sdk/version'
    try:
        return version_file.read_text(encoding='utf-8').strip()
    except OSError:
        return ''


def extract_pr_no():
    url = os.environ.get('PR_URL', '').strip()
    if not url:
        return None
    m = PR_NO_RE.search(url)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# Record building + validation
# ---------------------------------------------------------------------------

def _failed_case_details(shards):
    """failedCaseDetails list from per-shard failure items."""
    details = []
    for shard in shards.values():
        for item in shard['failures']:
            cid = '%s#%s' % (item['suite'], item['name'])
            detail = {'caseId': cid, 'caseName': item['name'],
                      'module': MODULE}
            reason = item['reason']
            if reason:
                if len(reason) > REASON_MAX:
                    reason = reason[:REASON_MAX] + '...'
                detail['reason'] = reason
            details.append(detail)
    return details


def _pr_fields(pr_no):
    """prNo/prUrl customFields (only when the gate exports PR_URL)."""
    if not pr_no:
        return []
    return [
        {'key': 'prNo', 'label': 'PR号', 'valueType': 'string',
         'value': pr_no,
         'description': 'Gate run merge request number (PR_URL)'},
        {'key': 'prUrl', 'label': 'PR链接', 'valueType': 'string',
         'value': PR_URL_TEMPLATE.format(pr_no),
         'description': 'Merge request page link (gitcode.com)'},
    ]


def _custom_fields(shards, totals, ctx, shard_failures):
    """customFields list: identity, PR link, round counters."""
    custom_fields = [
        {'key': 'runnerModule', 'label': '测试Runner', 'valueType': 'string',
         'value': MODULE,
         'description': 'SDK unit-test round collector (one record per '
                        'ci/test.sh round)'},
        {'key': 'sourceRunId', 'label': '来源运行', 'valueType': 'string',
         'value': ctx['round_id'],
         'description': 'Round identity derived from the round start (+08); '
                        'session stable key of the OBS daily merge'},
        {'key': 'buildHost', 'label': '构建主机', 'valueType': 'string',
         'value': platform.node(),
         'description': 'Host that executed the unit-test round'},
    ]
    custom_fields.extend(_pr_fields(extract_pr_no()))
    custom_fields.extend([
        {'key': 'testShards', 'label': '测试分片数', 'valueType': 'number',
         'value': len(shards),
         'description': 'Test shards reporting machine metrics this round'},
        {'key': 'shardFailures', 'label': '失败分片数', 'valueType': 'number',
         'value': len(shard_failures),
         'description': 'Test shards with failed dart runs or failed cases'},
        {'key': 'testSuites', 'label': '测试套件数', 'valueType': 'number',
         'value': totals['suites'],
         'description': 'dart test suites (test files) executed'},
        {'key': 'unfinishedCases', 'label': '未收尾用例数',
         'valueType': 'number', 'value': totals['unfinished'],
         'description': 'Started cases that never reported completion '
                        '(crash smoke tests); not counted in totalCases'},
        {'key': 'shardSummary', 'label': '分片明细', 'valueType': 'string',
         'value': shard_summary(shards),
         'description': 'Per-shard passed/total of non-hidden finished '
                        'cases; (F) marks a shard whose run failed'},
    ])
    return custom_fields


def _round_remark(ctx, totals, shard_count):
    """remark: provenance + round-specific notes."""
    remark = (
        'SDK unit-test round %s: aggregated from %d dart-test machine '
        'reports across %d shards by ci/scripts/collect_sdk_unit_dashboard'
        '.py (one record per round). Hidden suite-loading wrappers and '
        'framework-internal hidden lifecycle cases are excluded from case '
        'counts; cases skipped by test metadata count as skippedCases; '
        'analyze_all (dart analyze, not a test shard) is not part of '
        'testInfo.' % (ctx['round_id'], totals['files'], shard_count))
    if ctx.get('no_metrics'):
        remark += (' No dart test machine reports were found for this '
                   'round (testInfo is notRun).')
    if totals['parse_errors']:
        remark += ' (%d unparsable JSON lines skipped)' % (
            totals['parse_errors'])
    return remark


def _build_info_block(branch, commit, ctx, build_status, duration):
    """buildInfo: window, duration, status, command, environment."""
    env_parts = ['%s %s' % (platform.system(), platform.release())]
    dart_ver = dart_sdk_version()
    if dart_ver:
        env_parts.append('dart-sdk %s' % dart_ver)
    return {
        'buildNumber': None,
        'branch': branch,
        **({'commitId': commit} if commit else {}),
        'startTime': epoch_to_iso(ctx['round_start']),
        'endTime': epoch_to_iso(ctx['round_end']),
        'durationSeconds': duration,
        'durationText': duration_text(duration),
        'status': build_status,
        'buildCommand': ctx.get('build_command') or
                        DEFAULT_BUILD_COMMAND,
        'buildEnv': ' · '.join(env_parts),
    }


def _test_info_block(totals, shards, duration):
    """testInfo: case totals + failedCaseDetails when present."""
    passed = totals['passed']
    failed = totals['failed']
    skipped = totals['skipped']
    total = passed + failed + skipped
    failed_details = _failed_case_details(shards)
    return {
        'totalCases': total,
        'passedCases': passed,
        'failedCases': failed,
        'skippedCases': skipped,
        'passRate': round(passed / total * 100, 2) if total else None,
        'testStatus': 'failed' if failed else (
            'passed' if total else 'notRun'),
        'testProject': MODULE,
        'testDurationSeconds': duration,
        **({'failedCaseDetails': failed_details}
           if failed_details else {}),
    }


def _size_info_block(engine_bytes):
    """sizeInfo: host engine runtime size (no device HAP is built)."""
    breakdown = {'frameworkRuntime': round(engine_bytes / MB, 2)}
    return {
        'totalSizeMB': round(sum(breakdown.values()), 2),
        'unit': 'MB',
        'measureDescription': (
            'Host engine artifacts this round executed on '
            '(bin/cache/artifacts/engine/linux-x64, incl. the '
            'flutter_tester host runtime). SDK unit tests run on '
            'the host VM and build no device HAP, so the '
            'device-side HAP size metric does not apply.'),
        'breakdown': breakdown,
    }


def build_record(shards, totals, ctx):
    """One aggregate record for the round, or None if it cannot be valid."""
    shard_failures = [a['label'] for a in shards.values()
                      if a['run_failed'] or a['failed']]
    engine_bytes = measure_engine_artifacts()
    if not engine_bytes:
        # Schema requires sizeInfo.totalSizeMB > 0; without a measurable
        # runtime there is no valid record -> explicit skip.
        return None, ['skip: host engine artifacts not found (%s), cannot '
                      'build a valid sizeInfo' % (FLUTTER_ROOT /
                                                  ENGINE_ARTIFACTS_REL)]
    branch, commit = git_identity()
    duration = int(ctx['round_end'] - ctx['round_start'])
    build_status = 'failed' if (shard_failures or ctx.get('no_metrics')) \
        else 'success'
    record = {
        'recordId': 'flutter-%s-%s-001' % (
            branch, date_key_for(ctx['round_start'])),
        'reportTime': now_iso(),
        'basicInfo': {
            'frameworkType': 'flutter',
            'frameworkVersion': branch,
            'targetPlatform': '%s (host)' % platform.system(),
            'buildMode': 'debug',
            'buildInfo': _build_info_block(
                branch, commit, ctx, build_status, duration),
            'testInfo': _test_info_block(totals, shards, duration),
            'sizeInfo': _size_info_block(engine_bytes),
        },
        'extensionInfo': {
            'links': {'sourceRepoUrl': SOURCE_REPO_URL},
            'tags': ['harmonyos', 'sdk-unit'],
            'customFields': _custom_fields(
                shards, totals, ctx, shard_failures),
            'remark': _round_remark(ctx, totals, len(shards)),
        },
    }
    return record, []


def shard_summary(shards):
    parts = []
    for shard in shards.values():
        text = '%s %d/%d' % (shard['label'], shard['passed'], shard['total'])
        if shard['run_failed'] or shard['failed']:
            text += ' (F)'
        parts.append(text)
    return '; '.join(parts)


def _schema_errors(record, schema):
    """Optional schema validation through the document's records[] slot."""
    if not schema:
        return []
    try:
        import jsonschema
    except ImportError:
        return ['warn: jsonschema not installed, schema check '
                'skipped (business rules only)']
    # Validate through the document's records[] slot so internal
    # $refs resolve against the root schema.
    try:
        jsonschema.validate({
            'schemaVersion': '1.0.0',
            'generatedAt': record.get('reportTime') or now_iso(),
            'records': [record],
        }, schema)
    except jsonschema.ValidationError as exc:
        return ['schema: %s (path: %s)' % (
            exc.message, list(exc.absolute_path))]
    return []


def _time_errors(record):
    """R1/R5: +08 wall-clock build window, duration math, status enum."""
    rid = record.get('recordId', '')
    errors = []
    bi = record['basicInfo']['buildInfo']
    st = bi.get('startTime') or ''
    et = bi.get('endTime') or ''
    if not (st.endswith('+08:00') and et.endswith('+08:00')):
        errors.append('R1: %s build times must be +08 ISO strings' % rid)
    elif int((datetime.fromisoformat(et) -
              datetime.fromisoformat(st)).total_seconds()) != \
            bi['durationSeconds']:
        errors.append('R1: %s durationSeconds != endTime-startTime' % rid)
    if bi.get('durationText') != duration_text(bi['durationSeconds']):
        errors.append('R1: %s durationText inconsistent' % rid)
    if bi.get('status') not in ('success', 'failed'):
        errors.append('R5: %s unexpected buildInfo.status' % rid)
    return errors


def _test_info_errors(record):
    """R2/R3/R4/R7: case-count identities and status consistency."""
    rid = record.get('recordId', '')
    errors = []
    ti = record['basicInfo']['testInfo']
    if ti['totalCases'] != ti['passedCases'] + ti['failedCases'] + \
            ti['skippedCases']:
        errors.append('R2: %s totalCases != passed+failed+skipped' % rid)
    if ti['totalCases'] == 0:
        if ti['passRate'] is not None:
            errors.append('R3: %s passRate must be null when totalCases=0'
                          % rid)
        if ti['testStatus'] != 'notRun':
            errors.append('R4: %s testStatus must be notRun when '
                          'totalCases=0' % rid)
    else:
        expected_rate = round(ti['passedCases'] / ti['totalCases'] * 100, 2)
        if ti['passRate'] != expected_rate:
            errors.append('R3: %s passRate calculation mismatch' % rid)
        expected_status = 'failed' if ti['failedCases'] else 'passed'
        if ti['testStatus'] != expected_status:
            errors.append('R4: %s testStatus should be %s' % (
                rid, expected_status))
    if len(ti.get('failedCaseDetails') or []) != ti['failedCases']:
        errors.append('R7: %s failedCaseDetails count != failedCases' % rid)
    return errors


def _size_and_field_errors(record):
    """R6/R7: size math and customFields key uniqueness."""
    rid = record.get('recordId', '')
    errors = []
    si = record['basicInfo']['sizeInfo']
    if si['totalSizeMB'] <= 0:
        errors.append('R6: %s totalSizeMB must be > 0' % rid)
    if abs(sum(si['breakdown'].values()) - si['totalSizeMB']) > 0.01:
        errors.append('R6: %s breakdown sum != totalSizeMB' % rid)
    keys = [cf['key'] for cf in
            record['extensionInfo'].get('customFields') or []]
    if len(keys) != len(set(keys)):
        errors.append('R7: %s customFields key duplicated' % rid)
    return errors


def validate_record(record, schema):
    """Business-rule self-check + optional schema validation. [] = clean."""
    errors = _schema_errors(record, schema)
    rid = record.get('recordId', '')
    if not RECORD_ID_RE.match(rid):
        errors.append('R7: recordId malformed: %r' % rid)
    errors.extend(_time_errors(record))
    errors.extend(_test_info_errors(record))
    errors.extend(_size_and_field_errors(record))
    return errors


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def write_json_atomic(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name('%s.%d.tmp' % (path.name, os.getpid()))
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n',
                   encoding='utf-8')
    os.replace(str(tmp), str(path))


def resolve_log_dir(args_log_dir):
    if args_log_dir:
        return Path(args_log_dir)
    work_dir = os.environ.get('WORK_DIR', '')
    if work_dir:
        return Path(work_dir) / 'Archive/out/unit_tests_logs'
    return FLUTTER_ROOT.parents[1] / 'Archive/out/unit_tests_logs'


def print_notes(notes):
    for note in notes:
        print(note)


def build_parser():
    parser = argparse.ArgumentParser(
        description='Collect one framework-data record per SDK unit-test '
                    'round (see module docstring for the data flow).')
    parser.add_argument('--log-dir', default=None,
                        help='unit_tests_logs dir (default: '
                             '$WORK_DIR/Archive/out/unit_tests_logs)')
    parser.add_argument('--round-start', type=float, default=None,
                        help='round start epoch seconds (default: '
                             'derived from the metric files)')
    parser.add_argument('--round-end', type=float, default=None,
                        help='round end epoch seconds (default: now with '
                             '--round-start, else the last metric event)')
    parser.add_argument('--schema', default=None,
                        help='framework-data schema (default: '
                             'ci/resources/framework-data.schema.json)')
    parser.add_argument('--archive', action='store_true',
                        help='after collecting the round, also merge every '
                             'pending per-round dashboard file into the '
                             'OBS daily file (archived ones move to '
                             'dashboard/uploaded/)')
    parser.add_argument('--dry-run', action='store_true',
                        help='validate only, write/upload nothing')
    return parser


def derive_round_window(log_dir, files, args, notes):
    """Derive the round window from the metric files themselves.

    Returns (round_start, round_end, files) or None when no window can be
    derived; prints the skip reason itself in that case.
    """
    if not files:
        print_notes(notes)
        print('skip: no metrics files under %s, cannot define a round'
              % log_dir)
        return None
    _, probe = collect_round(files)
    round_start = round_end = None
    if probe['first_start'] is not None:
        round_start = int(probe['first_start'])
        if args.round_end is not None:
            round_end = int(args.round_end)
        elif probe['last_end'] is not None:
            round_end = int(probe['last_end'])
    if round_start is None:
        print_notes(notes)
        print('skip: cannot determine round window')
        return None
    # The derived window covers exactly the scanned (all) files;
    # re-scan scoped to keep one code path and drop nothing.
    files, more_notes = scan_metric_files(log_dir, round_start)
    notes.extend(more_notes)
    return round_start, round_end, files


def load_schema(args, notes):
    """Contract schema from --schema or the vendored default; None=warn."""
    schema_path = Path(args.schema) if args.schema else \
        FLUTTER_ROOT / 'ci' / 'resources' / 'framework-data.schema.json'
    if not schema_path.is_file():
        notes.append('warn: schema not found: %s' % schema_path)
        return None
    try:
        return json.loads(schema_path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as exc:
        notes.append('warn: schema unreadable (%s): %s'
                     % (schema_path, exc))
        return None


def emit_dataset(log_dir, ctx, record, shards, totals, args, notes):
    """Print the round summary and write the dataset files."""
    dataset = {
        'schemaVersion': '1.0.0',
        'generatedAt': now_iso(),
        'dataSource': (
            'flutter_flutter SDK unit-test round (ci/scripts/'
            'collect_sdk_unit_dashboard.py): one aggregate record per '
            'ci/test.sh round, assembled from dart test machine reports'),
        'records': [record],
    }
    print_notes(notes)
    print('record: %s cases=%d passed=%d failed=%d skipped=%d shards=%d '
          'suites=%d' % (record['recordId'],
                         record['basicInfo']['testInfo']['totalCases'],
                         record['basicInfo']['testInfo']['passedCases'],
                         record['basicInfo']['testInfo']['failedCases'],
                         record['basicInfo']['testInfo']['skippedCases'],
                         len(shards), totals['suites']))
    if args.dry_run:
        print('dry-run: dataset validated, nothing written')
        return 0
    out_main = log_dir / 'framework-data.json'
    out_round = log_dir / 'dashboard' / (
        'framework-data_%s.json' % ctx['round_id'])
    try:
        write_json_atomic(out_main, dataset)
        write_json_atomic(out_round, dataset)
    except OSError as exc:
        print('warn: dataset write failed: %s' % exc)
        return 1
    print('written: %s' % out_main)
    print('written: %s' % out_round)
    return 0


def _validate_and_emit(log_dir, ctx, record, shards, totals, args, notes):
    """Schema + business-rule validation, then print/write. Exit code."""
    schema = load_schema(args, notes)
    findings = validate_record(record, schema)
    errors = [e for e in findings if not e.startswith('warn')]
    notes.extend(e for e in findings if e.startswith('warn'))
    if errors:
        notes.extend(errors)
        notes.append('VALIDATION FAILED - zero write')
        print_notes(notes)
        return 1
    return emit_dataset(log_dir, ctx, record, shards, totals, args, notes)


def run_collect(log_dir, args, notes):
    """Collect-mode flow: aggregate one round into a dashboard record."""
    window_given = args.round_start is not None
    files, scan_notes = scan_metric_files(log_dir, args.round_start)
    notes.extend(scan_notes)
    round_end = None
    if window_given:
        round_start = int(args.round_start)
    else:
        # No explicit window: derive it from the metric files themselves
        # (first file start .. last file end); a fresh log dir contains
        # exactly one round.
        derived = derive_round_window(log_dir, files, args, notes)
        if derived is None:
            return 0
        round_start, round_end, files = derived
    if round_end is None:
        round_end = int(args.round_end if args.round_end is not None
                        else time.time())
    if round_end < round_start:
        round_end = round_start

    shards, totals = collect_round(files)
    no_metrics = not files
    if no_metrics and not window_given:
        # An empty scan cannot even define a round (handled above);
        # keep this guard for safety.
        print_notes(notes)
        print('skip: no metric files for the derived round window')
        return 0
    if no_metrics:
        notes.append('warn: no dart test machine reports in the round '
                     'window (every invocation failed before reporting?)')
    ctx = {
        'round_start': round_start,
        'round_end': round_end,
        'round_id': round_id_for(round_start),
        'no_metrics': no_metrics,
    }

    record, build_notes = build_record(shards, totals, ctx)
    notes.extend(build_notes)
    if record is None:
        print_notes(notes)
        return 1
    return _validate_and_emit(log_dir, ctx, record, shards, totals,
                              args, notes)


def main(argv=None):
    args = build_parser().parse_args(argv)
    notes = []
    log_dir = resolve_log_dir(args.log_dir)
    if not log_dir.is_dir():
        print('skip: unit-test log dir not found: %s' % log_dir)
        return 0
    rc = run_collect(log_dir, args, notes)
    if args.archive:
        # Collect first, then archive: this round's per-round file (plus
        # any older pending one) merges into the OBS daily file; a
        # collect failure never stops the catch-up archiving.
        mark = len(notes)
        rc |= run_archive(log_dir, args, notes)
        print_notes(notes[mark:])
    return rc


# ---------------------------------------------------------------------------
# --archive: pending per-round copies -> OBS daily file (cipd archive CLI)
# ---------------------------------------------------------------------------

# cloud_test://<path> maps to obs://flutter-ohos-test/<path>: the same
# bucket/prefix the CPF-Flutter/tests collector archives its daily files to.
# Measured CLI contract (stub-obsutil matrix, 2026-11-24): success -> rc=0
# with passthrough output; EVERY failure (auth / network / missing object /
# bad config) -> rc=1 with empty output. `archive init` is the only way a
# fresh CI pod can obtain the $HOME/.obsutilconfig the CLI relies on.
ARCHIVE_DAILY_KEY = 'cloud_test://flutter/daily_data/%s/framework-data.json'
ARCHIVE_ROUND_RE = re.compile(r'^framework-data_unit_tests_(\d{8})_\d{6}\.json$')
RECID_SEQ_RE = re.compile(r'-(\d{8})-(\d+)$')  # recordId tail: -<date>-<seq>
UPLOADED_SUBDIR = 'uploaded'
REJECTED_SUBDIR = 'rejected'
ARCHIVE_CALL_TIMEOUT = 30    # per CLI call; one retry attempt makes at
                             # most 3 calls (download, upload, verify)
ARCHIVE_UPLOAD_RETRIES = 3   # read-merge-upload-verify attempts per date


def archive_cli():
    """cipd archive CLI from PATH (same invocation as upload_to_cloud.sh)."""
    return shutil.which('archive')


def archive_init_cli(exe, notes):
    """Best-effort `archive init` (idempotent): writes the $HOME
    .obsutilconfig that the CLI's obsutil invocations rely on -- a fresh
    CI pod has none. Failure is WARN-only: a pre-configured host keeps
    working, a broken one becomes diagnosable instead of silent."""
    rc, out = run_archive_cli(exe, ['init'])
    if rc == 0:
        notes.append('archive: init ok')
        return True
    notes.append('WARN: archive init failed, obsutil config may be missing '
                 'on this host [rc=%s out=%r]'
                 % (rc, (out or '').strip()[-200:]))
    return False


def obsutil_config_path():
    """The $HOME/.obsutilconfig that `archive init` writes and
    `archive uninstall` removes."""
    return Path.home() / '.obsutilconfig'


def archive_uninstall_cli(exe, notes):
    """Best-effort `archive uninstall` once uploading is done: drops the
    $HOME/.obsutilconfig bootstrapped by `archive init` so the CLI's
    credentials never linger on the host. Only called when this run
    bootstrapped the file itself; failure is WARN-only."""
    rc, out = run_archive_cli(exe, ['uninstall'])
    if rc == 0:
        notes.append('archive: uninstall ok')
        return True
    notes.append('WARN: archive uninstall failed [rc=%s out=%r]'
                 % (rc, (out or '').strip()[-200:]))
    return False


def run_archive_cli(exe, args):
    """Run the archive CLI; returns (rc, combined output) or (None, reason)."""
    try:
        res = subprocess.run(
            [exe] + list(args), capture_output=True, text=True,
            encoding='utf-8', errors='replace', timeout=ARCHIVE_CALL_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, 'archive timeout after %ds' % ARCHIVE_CALL_TIMEOUT
    except OSError as exc:
        return None, 'archive exec failed: %s' % exc
    return res.returncode, (res.stdout or '') + (res.stderr or '')


def archive_missing(rc, out):
    """True when the CLI reported 'object does not exist' (rc 6 / 404 text).

    The current archive CLI normalizes every obsutil failure to rc=1 with
    empty output, so this never fires and a fresh day's missing object is
    deliberately classified as 'error' instead: wrongly guessing 'missing'
    would overwrite the existing daily file and destroy other writers'
    records. Patterns stay for forward compatibility -- the moment the
    CLI passes rc/text through, fresh-day detection works on its own.
    """
    if rc == 0:
        return False
    if 'NoSuchBucket' in out:
        return False
    return rc == 6 or 'NoSuchKey' in out or 'Status [404]' in out \
        or 'does not exist' in out


def archive_download(exe, remote, local):
    return run_archive_cli(exe, ['cp', remote, str(local)])


def archive_upload(exe, local, remote):
    return run_archive_cli(exe, ['cp', str(local), remote])


def record_custom(rec, key):
    for cf in (rec.get('extensionInfo') or {}).get('customFields') or []:
        if cf.get('key') == key:
            return cf.get('value')
    return None


def session_record_key(rec):
    """Session stable key; retries and re-merges reuse the same slot."""
    return (record_custom(rec, 'sourceRunId'),
            record_custom(rec, 'runnerModule'),
            record_custom(rec, 'buildHost'))


def _day_slots(existing_records, date_key):
    """(next_seq, replace_idx): next day-global sequence + session slots."""
    seqs = [int(m.group(2)) for rec in existing_records
            for m in [RECID_SEQ_RE.search(rec.get('recordId') or '')] if m]
    next_seq = max(seqs) + 1 if seqs else 1
    replace_idx = {}
    for idx, rec in enumerate(existing_records):
        m = RECID_SEQ_RE.search(rec.get('recordId') or '')
        if m and m.group(1) == date_key:
            key = session_record_key(rec)
            if key[0] is not None and key[1] is not None:
                replace_idx.setdefault(key, idx)
    return next_seq, replace_idx


def _merge_session_records(existing_records, session_records, date_key,
                           next_seq, replace_idx):
    """Merge records in place: same-session records replace, others append."""
    merged_records = list(existing_records)
    my_final = []
    for rec in session_records:
        final = dict(rec)
        idx = replace_idx.get(session_record_key(final))
        if idx is not None:
            final['recordId'] = merged_records[idx].get('recordId')
            merged_records[idx] = final
        else:
            rid = final.get('recordId') or ''
            head = rid.rsplit('-', 1)[0] if rid else \
                '%s-unknown-%s' % ((final.get('basicInfo') or {}).get(
                    'frameworkType', 'flutter'), date_key)
            final['recordId'] = '%s-%03d' % (head, next_seq)
            next_seq += 1
            merged_records.append(final)
        my_final.append(final)
    return merged_records, my_final


def merge_daily_dataset(existing_doc, session_records, date_key, now):
    """Merge records into the day file; zero write on validation failure.

    Existing records are preserved as-is; a record whose session key is
    already present on the same date replaces it in place (idempotent),
    others are appended with the next day-global sequence number.
    """
    notes = []
    if existing_doc is None:
        existing_doc = {'schemaVersion': '1.0.0', 'records': []}
    existing_records = existing_doc.get('records')
    if not isinstance(existing_records, list):
        notes.append('WARN: daily file of %s has non-list records, zero '
                     'write to keep it' % date_key)
        return None, None, notes
    next_seq, replace_idx = _day_slots(existing_records, date_key)
    merged_records, my_final = _merge_session_records(
        existing_records, session_records, date_key, next_seq, replace_idx)

    errors = []
    for rec in my_final:
        errors.extend(e for e in validate_record(rec, None)
                      if not e.startswith('warn'))
    if errors:
        notes.extend(errors)
        notes.append('WARN: session records failed re-validation, zero '
                     'write')
        return None, None, notes
    all_ids = [rec.get('recordId') for rec in merged_records]
    if len(set(all_ids)) != len(all_ids):
        notes.append('WARN: duplicate recordIds in the merged daily file '
                     '(pre-existing records kept as-is)')

    merged_doc = dict(existing_doc)
    merged_doc['schemaVersion'] = existing_doc.get('schemaVersion') \
        or '1.0.0'
    merged_doc['generatedAt'] = now.isoformat()
    merged_doc['dataSource'] = ('flutter_flutter SDK unit-test daily merge '
                                '(one record per round, session-key '
                                'idempotent)')
    merged_doc['records'] = merged_records
    return merged_doc, my_final, notes


def download_daily_doc(exe, daily_key, local_path):
    """(status, doc, detail): ok / missing (fresh day) / error."""
    if local_path.exists():
        local_path.unlink()
    rc, out = archive_download(exe, daily_key, local_path)
    detail = 'rc=%s out=%r' % (rc, (out or '').strip()[-160:])
    if rc == 0 and local_path.is_file():
        try:
            return 'ok', json.loads(
                local_path.read_text(encoding='utf-8')), detail
        except (OSError, ValueError) as exc:
            return 'error', None, '%s (unparsable: %s)' % (detail, exc)
    if archive_missing(rc, out):
        return 'missing', None, detail
    return 'error', None, detail


def verify_daily_doc(exe, daily_key, local_path, my_final):
    """Re-download the day file and check my final recordIds are in place."""
    status, doc, _detail = download_daily_doc(exe, daily_key, local_path)
    if status != 'ok' or not isinstance(doc, dict):
        return False
    got_ids = set()
    for rec in doc.get('records') or []:
        if isinstance(rec, dict):
            got_ids.add(rec.get('recordId'))
    return all(rec.get('recordId') in got_ids for rec in my_final)


def move_round_file(path, subdir):
    dest_dir = path.parent / subdir
    dest_dir.mkdir(parents=True, exist_ok=True)
    os.replace(str(path), str(dest_dir / path.name))


def _inspect_round_file(path):
    """(date_key, records, bad) for one pending per-round file."""
    try:
        doc = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as exc:
        return None, None, 'unreadable: %s' % exc
    records = doc.get('records') if isinstance(doc, dict) else None
    if not isinstance(records, list) or not records:
        return None, None, 'no records'
    try:
        errors = [e for rec in records
                  for e in validate_record(rec, None)
                  if not e.startswith('warn')]
    except Exception as exc:  # malformed record shape
        errors = ['malformed record: %r' % exc]
    if errors:
        return None, None, 'validation failed: %s' % '; '.join(errors)
    date_keys = set()
    for rec in records:
        m = RECID_SEQ_RE.search(rec.get('recordId') or '')
        date_keys.add(m.group(1) if m else None)
    if None in date_keys or len(date_keys) != 1:
        return None, None, 'record date not derivable'
    return date_keys.pop(), records, None


def scan_pending_rounds(dash_dir, notes, quarantine=True):
    """Group un-archived per-round files by record date.

    Pending files sit directly in dashboard/ (processed ones live in the
    uploaded/ and rejected/ subdirectories, so a flat glob sees only
    pending files). Invalid files are quarantined so they never block the
    valid ones. Returns (OrderedDict date_key -> [(path, records)], count).
    """
    groups = OrderedDict()
    quarantined = 0
    for path in sorted(dash_dir.glob('framework-data_*.json')):
        if not ARCHIVE_ROUND_RE.match(path.name):
            continue  # not a per-round file, leave it alone
        date_key, records, bad = _inspect_round_file(path)
        if bad is None:
            groups.setdefault(date_key, []).append((path, records))
        else:
            notes.append('WARN: %s (%s)' % (
                'quarantined' if quarantine else 'would quarantine',
                path.name) + ' - ' + bad)
            if quarantine:
                move_round_file(path, REJECTED_SUBDIR)
            quarantined += 1
    return groups, quarantined


def _archive_attempt(exe, date_key, items, attempt, temp_dir, notes):
    """One read-merge-upload-verify attempt: 'ok' / 'fail' / 'retry'.

    'retry' sleeps before returning so the next attempt backs off.
    """
    daily_key = ARCHIVE_DAILY_KEY % date_key
    status, existing_doc, detail = download_daily_doc(
        exe, daily_key, temp_dir / ('daily-%s.json' % date_key))
    if status == 'error':
        # Ambiguous CLI failure (see archive_missing): retry covers
        # transient errors, the attempt loop bounds the total; on
        # give-up the files stay pending. Never fall back to merging
        # from an empty day file here -- that would overwrite records
        # written by other collectors.
        notes.append('WARN: daily file download failed (%s), attempt %d, '
                     'keep pending [%s]' % (date_key, attempt, detail))
        time.sleep(1.0 + random.random())
        return 'retry'
    merged_doc, my_final, merge_notes = merge_daily_dataset(
        existing_doc, [rec for _path, recs in items for rec in recs],
        date_key, datetime.now(TZ))
    notes.extend(merge_notes)
    if merged_doc is None:
        return 'fail'  # zero write, files stay pending
    staging = temp_dir / ('staging-%s.json' % date_key)
    staging.write_text(
        json.dumps(merged_doc, ensure_ascii=False, indent=2) + '\n',
        encoding='utf-8')
    rc, out = archive_upload(exe, staging, daily_key)
    if rc != 0:
        notes.append('WARN: daily upload attempt %d failed (%s): rc=%s '
                     'out=%r' % (attempt, date_key, rc,
                                 (out or '').strip()[-160:]))
        time.sleep(1.0 + random.random())
        return 'retry'
    verify_path = temp_dir / ('verify-%s.json' % date_key)
    if verify_daily_doc(exe, daily_key, verify_path, my_final):
        for path, _recs in items:
            move_round_file(path, UPLOADED_SUBDIR)
        notes.append('archive: recordIds of %s: %s' % (
            date_key, ', '.join(
                rec.get('recordId') or '?' for rec in my_final)))
        return 'ok'
    notes.append('WARN: post-upload verify failed (attempt %d, %s), '
                 'concurrent overwrite suspected' % (attempt, date_key))
    time.sleep(1.0 + random.random() * 2.0)
    return 'retry'


def archive_one_date(exe, date_key, items, temp_dir, notes):
    """Read existing -> merge -> upload -> verify; move files on success.

    Concurrency: no lock object is used. The archive CLI cannot delete one,
    and a lock left behind until TTL expiry would block the
    CPF-Flutter/tests collector (stat-based freshness) for up to 10 minutes
    and silently drop its daily merges. Instead every attempt re-reads the
    day file and the upload is verified by read-back: a race costs at most
    a retry, and the session-key merge is idempotent, so concurrent writers
    converge to one record per session.
    """
    notes.append('archive: %d file(s) of %s -> %s'
                 % (len(items), date_key, ARCHIVE_DAILY_KEY % date_key))
    for attempt in range(1, ARCHIVE_UPLOAD_RETRIES + 1):
        outcome = _archive_attempt(
            exe, date_key, items, attempt, temp_dir, notes)
        if outcome != 'retry':
            return outcome == 'ok'
    notes.append('WARN: archive of %s gave up after %d attempts, keep '
                 'pending' % (date_key, ARCHIVE_UPLOAD_RETRIES))
    return False


def _archive_dashboard_dir(dash_dir, args, notes):
    """Archive mode core; assumes the dashboard dir exists."""
    groups, quarantined = scan_pending_rounds(
        dash_dir, notes, quarantine=not args.dry_run)
    if not groups:
        notes.append('skip: no pending per-round files under %s' % dash_dir)
        return 1 if quarantined else 0
    if args.dry_run:
        for date_key in sorted(groups):
            notes.append('dry-run: would archive %d file(s) of %s'
                         % (len(groups[date_key]), date_key))
        notes.append('dry-run: pending datasets validated, nothing '
                     'uploaded, nothing moved')
        return 0
    exe = archive_cli()
    if exe is None:
        notes.append('WARN: archive CLI not found on PATH, keep %d '
                     'file(s) pending'
                     % sum(len(v) for v in groups.values()))
        return 1
    # Only a run that bootstrapped the obsutil config may uninstall it:
    # a host with a pre-configured .obsutilconfig keeps its own file.
    bootstrapped_config = not obsutil_config_path().exists()
    archive_init_cli(exe, notes)
    temp_dir = Path(tempfile.mkdtemp(prefix='sdk-dash-archive-'))
    try:
        failed = quarantined + sum(
            0 if archive_one_date(exe, date_key, groups[date_key],
                                  temp_dir, notes) else 1
            for date_key in sorted(groups))
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
        if bootstrapped_config:
            archive_uninstall_cli(exe, notes)
    return 1 if failed else 0


def run_archive(log_dir, args, notes):
    """--archive entry: merge every pending per-round file into its OBS
    daily file. Returns a process exit code (0 = all clean / nothing to
    do, 1 = something WARN-worthy; pending files are never lost)."""
    dash_dir = log_dir / 'dashboard'
    if not dash_dir.is_dir():
        notes.append('skip: no dashboard dir under %s (nothing to archive)'
                     % log_dir)
        return 0
    try:
        return _archive_dashboard_dir(dash_dir, args, notes)
    except Exception as exc:  # archiving must never fail the pipeline
        notes.append('WARN: archive failed: %s' % exc)
        return 1


if __name__ == '__main__':
    sys.exit(main())
