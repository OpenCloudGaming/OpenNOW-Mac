import { spawn } from "node:child_process";
import { relative } from "node:path";

export async function updateStatus(repoRoot, options = {}) {
  const branch = options.branch || "";
  const status = await git(repoRoot, ["status", "--porcelain"]);
  const currentBranch = await git(repoRoot, ["rev-parse", "--abbrev-ref", "HEAD"]);
  const upstream = await git(repoRoot, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], { allowFailure: true });
  const head = await git(repoRoot, ["rev-parse", "HEAD"]);

  if (branch && currentBranch.stdout.trim() !== branch) {
    return {
      clean: status.stdout.trim().length === 0,
      branch: currentBranch.stdout.trim(),
      expectedBranch: branch,
      upstream: upstream.code === 0 ? upstream.stdout.trim() : "",
      head: head.stdout.trim(),
      updateAvailable: false,
      pendingCommits: [],
      blockedReason: `current branch is ${currentBranch.stdout.trim()}, expected ${branch}`
    };
  }

  if (upstream.code !== 0) {
    return {
      clean: status.stdout.trim().length === 0,
      branch: currentBranch.stdout.trim(),
      expectedBranch: branch,
      upstream: "",
      head: head.stdout.trim(),
      updateAvailable: false,
      pendingCommits: [],
      blockedReason: "current branch has no upstream"
    };
  }

  await git(repoRoot, ["fetch", "--prune"]);
  const upstreamRef = upstream.stdout.trim();
  const behindCount = await git(repoRoot, ["rev-list", "--count", `HEAD..${upstreamRef}`]);
  const commits = await git(repoRoot, ["log", "--oneline", `HEAD..${upstreamRef}`], { allowFailure: true });

  return {
    clean: status.stdout.trim().length === 0,
    branch: currentBranch.stdout.trim(),
    expectedBranch: branch,
    upstream: upstreamRef,
    head: head.stdout.trim(),
    updateAvailable: Number.parseInt(behindCount.stdout.trim(), 10) > 0,
    pendingCommits: commits.stdout.trim() ? commits.stdout.trim().split("\n") : [],
    blockedReason: status.stdout.trim().length === 0 ? "" : "worktree has uncommitted changes"
  };
}

export async function applyGitUpdate(repoRoot, options = {}) {
  const beforeStatus = await updateStatus(repoRoot, options);
  if (beforeStatus.blockedReason) return { applied: false, beforeStatus, blockedReason: beforeStatus.blockedReason };
  if (!beforeStatus.updateAvailable) return { applied: false, beforeStatus, blockedReason: "already up to date" };

  const requireSignedCommits = options.requireSignedCommits !== false;
  if (requireSignedCommits) {
    const signatureCheck = await verifyCommitSignatures(repoRoot, beforeStatus.upstream);
    if (!signatureCheck.verified) {
      return { applied: false, beforeStatus, blockedReason: signatureCheck.reason, signatureCheck };
    }
  }

  const changedFilesBeforePull = await git(repoRoot, ["diff", "--name-only", "HEAD", beforeStatus.upstream]);
  const candidateChangedFiles = changedFilesBeforePull.stdout.trim() ? changedFilesBeforePull.stdout.trim().split("\n") : [];
  await git(repoRoot, ["pull", "--ff-only"]);

  const validationCommand = options.validationCommand || "node RemoteCoOp/run-servers.mjs --dry-run";
  const validation = validationCommand ? await runShell(repoRoot, validationCommand, 120_000) : { code: 0, stdout: "", stderr: "" };
  const afterStatus = await updateStatus(repoRoot, options);
  const changedPanelFiles = candidateChangedFiles.filter(file => file === "RemoteCoOp/run-servers.mjs" || file.startsWith("RemoteCoOp/panel/") || file.startsWith("RemoteCoOp/service/"));

  return {
    applied: validation.code === 0,
    beforeStatus,
    afterStatus,
    validation,
    changedFiles: candidateChangedFiles.map(file => relative(repoRoot, file).startsWith("..") ? file : file),
    changedPanelFiles,
    blockedReason: validation.code === 0 ? "" : "validation failed"
  };
}

async function verifyCommitSignatures(repoRoot, upstreamRef, options = {}) {
  const commitListResult = await git(repoRoot, ["rev-list", "HEAD.." + upstreamRef], { allowFailure: true });
  if (commitListResult.code !== 0) {
    return { verified: false, reason: "failed to list commits" };
  }
  const commitHashes = commitListResult.stdout.trim().split("\n").filter(Boolean);
  if (commitHashes.length === 0) {
    return { verified: true, reason: "no commits to verify" };
  }

  const allowedFingerprints = Array.isArray(options.allowedSignerFingerprints) ? options.allowedSignerFingerprints : [];

  for (const hash of commitHashes) {
    const verifyResult = await git(repoRoot, ["verify-commit", "--quiet", hash], { allowFailure: true });
    if (verifyResult.code !== 0) {
      return { verified: false, reason: `commit ${hash.slice(0, 8)} is not signed or signature is invalid`, commit: hash };
    }
    if (allowedFingerprints.length > 0) {
      const fingerprintResult = await getCommitSignerFingerprint(repoRoot, hash);
      if (!fingerprintResult.fingerprint) {
        return { verified: false, reason: `commit ${hash.slice(0, 8)} has no signer fingerprint`, commit: hash };
      }
      if (!allowedFingerprints.includes(fingerprintResult.fingerprint)) {
        return { verified: false, reason: `commit ${hash.slice(0, 8)} signed by untrusted key ${fingerprintResult.fingerprint.slice(-16)}`, commit: hash, fingerprint: fingerprintResult.fingerprint };
      }
    }
  }

  return { verified: true, reason: `verified ${commitHashes.length} signed commit(s)`, commitCount: commitHashes.length };
}

async function getCommitSignerFingerprint(repoRoot, commitHash) {
  const result = await git(repoRoot, ["log", "-1", "--format=%GF", commitHash], { allowFailure: true });
  const fingerprint = result.stdout.trim();
  return { fingerprint: fingerprint || null };
}

async function git(cwd, args, options = {}) {
  const result = await run("git", args, { cwd, timeoutMilliseconds: options.timeoutMilliseconds ?? 120_000 });
  if (result.code !== 0 && !options.allowFailure) throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
  return result;
}

function runShell(cwd, command, timeoutMilliseconds) {
  return run(process.platform === "win32" ? "cmd.exe" : "/bin/sh", process.platform === "win32" ? ["/d", "/s", "/c", command] : ["-lc", command], { cwd, timeoutMilliseconds });
}

function run(command, args, options) {
  return new Promise(resolve => {
    const child = spawn(command, args, { cwd: options.cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) child.kill("SIGKILL");
    }, options.timeoutMilliseconds);

    child.stdout.on("data", chunk => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", chunk => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: 127, stdout, stderr: error.message });
    });
    child.on("close", code => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });
}
