import express from "express";
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const app = express();

const PORT = Number(process.env.PORT || 3000);
const CACHE_DIR = path.resolve("./cache");
const PLAN_CACHE_VERSION = "rules-v2";

const MANIFEST_URL =
  "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

const OS_ALIASES = {
  win: "windows",
  windows: "windows",
  linux: "linux",
  osx: "osx",
  mac: "osx",
  macos: "osx"
};

const ARCH_ALIASES = {
  x64: "x64",
  x86_64: "x64",
  amd64: "x64",
  x86: "x86",
  i386: "x86",
  arm64: "arm64",
  aarch64: "arm64"
};

function cachePath(...parts) {
  return path.join(CACHE_DIR, ...parts);
}

async function ensureDir(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
}

async function readJsonCache(file) {
  try {
    return JSON.parse(await fs.readFile(file, "utf8"));
  } catch {
    return null;
  }
}

async function writeJsonCache(file, data) {
  await ensureDir(file);
  await fs.writeFile(file, JSON.stringify(data, null, 2));
}

async function fetchJsonCached(file, url) {
  const cached = await readJsonCache(file);
  if (cached) return cached;

  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`Fetch failed ${res.status}: ${url}`);
  }

  const json = await res.json();
  await writeJsonCache(file, json);
  return json;
}

function sha1Text(value) {
  return crypto.createHash("sha1").update(value).digest("hex");
}

function normalizeOs(value) {
  return OS_ALIASES[String(value || "windows").toLowerCase()] || "windows";
}

function normalizeArch(value) {
  return ARCH_ALIASES[String(value || "x64").toLowerCase()] || "x64";
}

function allowedByRules(rules, osName, arch, features = {}) {
  if (!rules || rules.length === 0) return true;

  let allowed = false;

  for (const rule of rules) {
    const action = rule.action === "allow";
    let matches = true;

    if (rule.os) {
      if (rule.os.name && rule.os.name !== osName) {
        matches = false;
      }

      if (rule.os.arch) {
        const ruleArch = normalizeArch(rule.os.arch);
        if (ruleArch !== arch) matches = false;
      }
    }

    if (rule.features) {
      for (const [name, expected] of Object.entries(rule.features)) {
        if (Boolean(features[name]) !== Boolean(expected)) {
          matches = false;
          break;
        }
      }
    }

    if (matches) {
      allowed = action;
    }
  }

  return allowed;
}

function pushArg(out, kind, value, osName, arch) {
  if (typeof value === "string") {
    out.push(`${kind}|${value}`);
    return;
  }

  if (!value || typeof value !== "object") return;

  if (!allowedByRules(value.rules, osName, arch)) return;

  const v = value.value;

  if (Array.isArray(v)) {
    for (const item of v) out.push(`${kind}|${item}`);
  } else if (typeof v === "string") {
    out.push(`${kind}|${v}`);
  }
}

function resolveLibraryArtifact(lib, osName, arch) {
  if (!allowedByRules(lib.rules, osName, arch)) return null;

  const downloads = lib.downloads || {};

  const result = {
    artifact: downloads.artifact || null,
    native: null
  };

  if (lib.natives && downloads.classifiers) {
    let nativeKey = lib.natives[osName];

    if (nativeKey) {
      nativeKey = nativeKey.replace("${arch}", arch === "x64" ? "64" : "32");
      result.native = downloads.classifiers[nativeKey] || null;
    }
  }

  return result;
}

function safeLine(parts) {
  return parts.map((p) => String(p ?? "").replace(/\r?\n/g, "")).join("|");
}

async function buildPlan({ version, osName, arch }) {
  const manifest = await fetchJsonCached(
    cachePath("mojang", "version_manifest_v2.json"),
    MANIFEST_URL
  );

  let targetVersion = version;

  if (version === "latest" || version === "latest-release") {
    targetVersion = manifest.latest.release;
  }

  if (version === "latest-snapshot") {
    targetVersion = manifest.latest.snapshot;
  }

  const versionEntry = manifest.versions.find((v) => v.id === targetVersion);

  if (!versionEntry) {
    throw new Error(`Unknown Minecraft version: ${version}`);
  }

  const versionJson = await fetchJsonCached(
    cachePath("mojang", "versions", `${targetVersion}.json`),
    versionEntry.url
  );

  const assetIndex = await fetchJsonCached(
    cachePath("mojang", "assets", `${versionJson.assetIndex.id}.json`),
    versionJson.assetIndex.url
  );

  const lines = [];

  lines.push("# InlineMC launch plan");
  lines.push(safeLine(["VERSION", versionJson.id]));
  lines.push(safeLine(["VERSION_TYPE", versionJson.type || "release"]));
  lines.push(safeLine(["MAIN_CLASS", versionJson.mainClass]));
  lines.push(safeLine(["ASSET_INDEX_ID", versionJson.assetIndex.id]));

  const client = versionJson.downloads?.client;

  if (!client) {
    throw new Error(`Version has no client download: ${targetVersion}`);
  }

  const clientPath = `versions/${versionJson.id}/${versionJson.id}.jar`;

  lines.push(
    safeLine([
      "CLIENT",
      clientPath,
      client.sha1 || "",
      client.url,
      String(client.size || "")
    ])
  );

  lines.push(
    safeLine([
      "ASSET_INDEX",
      `assets/indexes/${versionJson.assetIndex.id}.json`,
      versionJson.assetIndex.sha1 || "",
      versionJson.assetIndex.url,
      String(versionJson.assetIndex.size || "")
    ])
  );

  const classpath = [];

  for (const lib of versionJson.libraries || []) {
    const resolved = resolveLibraryArtifact(lib, osName, arch);
    if (!resolved) continue;

    if (resolved.artifact) {
      classpath.push(resolved.artifact.path);

      lines.push(
        safeLine([
          "LIBRARY",
          resolved.artifact.path,
          resolved.artifact.sha1 || "",
          resolved.artifact.url,
          String(resolved.artifact.size || "")
        ])
      );
    }

    if (resolved.native) {
      lines.push(
        safeLine([
          "NATIVE",
          resolved.native.path,
          resolved.native.sha1 || "",
          resolved.native.url,
          String(resolved.native.size || ""),
          `versions/${versionJson.id}/natives`
        ])
      );
    }
  }

  classpath.push(clientPath);

  for (const cp of classpath) {
    lines.push(safeLine(["CLASSPATH", cp]));
  }

  for (const [assetName, asset] of Object.entries(assetIndex.objects || {})) {
    const hash = asset.hash;
    const prefix = hash.slice(0, 2);
    const objectPath = `assets/objects/${prefix}/${hash}`;
    const url = `https://resources.download.minecraft.net/${prefix}/${hash}`;

    lines.push(
      safeLine([
        "ASSET",
        objectPath,
        hash,
        url,
        String(asset.size || ""),
        assetName
      ])
    );
  }

  const jvmArgs = versionJson.arguments?.jvm || [];
  const gameArgs = versionJson.arguments?.game || [];

  if (jvmArgs.length > 0) {
    for (const arg of jvmArgs) {
      pushArg(lines, "JVM_ARG", arg, osName, arch);
    }
  } else {
    lines.push("JVM_ARG|-Djava.library.path=${NATIVES_DIR}");
    lines.push("JVM_ARG|-cp");
    lines.push("JVM_ARG|${CLASSPATH}");
  }

  if (gameArgs.length > 0) {
    for (const arg of gameArgs) {
      pushArg(lines, "GAME_ARG", arg, osName, arch);
    }
  } else if (versionJson.minecraftArguments) {
    for (const arg of versionJson.minecraftArguments.split(" ")) {
      if (arg.trim()) lines.push(safeLine(["GAME_ARG", arg.trim()]));
    }
  }

  lines.push("OFFLINE_DEFAULT|UUID|00000000-0000-0000-0000-000000000000");
  lines.push("OFFLINE_DEFAULT|ACCESS_TOKEN|0");
  lines.push("OFFLINE_DEFAULT|USER_TYPE|legacy");

  return lines.join("\n") + "\n";
}

app.get("/v1/plan.txt", async (req, res) => {
  try {
    const version = String(req.query.version || "latest-release");
    const osName = normalizeOs(req.query.os);
    const arch = normalizeArch(req.query.arch);

    const planKey = `${PLAN_CACHE_VERSION}_${version}_${osName}_${arch}`;
    const planHash = sha1Text(planKey).slice(0, 12);
    const planFile = cachePath("plans", `${planKey}_${planHash}.txt`);

    let plan;

    try {
      plan = await fs.readFile(planFile, "utf8");
    } catch {
      plan = await buildPlan({ version, osName, arch });
      await ensureDir(planFile);
      await fs.writeFile(planFile, plan);
    }

    res.type("text/plain").send(plan);
  } catch (err) {
    res.status(500).type("text/plain").send(String(err.stack || err));
  }
});

app.listen(PORT, () => {
  console.log(`InlineMC resolver running on http://localhost:${PORT}`);
});
