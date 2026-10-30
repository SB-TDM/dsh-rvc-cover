import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

/**
 * Bundled `rvc-cover` skill provider.
 *
 * Registers one skill that carries the whole cover workflow (separation →
 * pitch match → RVC conversion → mix) plus its helper scripts, so the agent
 * decides with the manual and executes with ordinary shell + file tools.
 * No Host tool is registered: every step needs a local engine and a human ear,
 * and a tool that shells out to an uninstalled engine only produces failures.
 */

/** Provider identity shown in diagnostics. */
const PROVIDER_NAME = "rvc-cover";
/** Skill name; must satisfy the public skill-name grammar. */
const SKILL_NAME = "rvc-cover";
/** Skill body, resolved beside the package. */
const SKILL_BODY_URL = new URL("../assets/SKILL.md", import.meta.url);
/** Scripts and references handed to the agent as skill resources. */
const RESOURCE_BASE = {
	kind: "directory",
	path: fileURLToPath(new URL("../assets/", import.meta.url))
};

const DESCRIPTION =
	"Use when the user wants a song re-sung in a target voice (翻唱 / 换音色 / 让某个角色唱这首歌), or wants an agent's speaking voice and singing voice to be the same person. Covers the 6GB local pipeline: vocal separation, pitch-shift matching, RVC conversion with a prebuilt model, mixing and loudness normalisation, plus the preconditions and failure matrix.";

/** Packaged-provider precedence rank (BUNDLED_SKILL_RANK). */
const BUNDLED_RANK = 600;

const CANDIDATE = {
	name: SKILL_NAME,
	description: DESCRIPTION,
	invocation: { modelInvocable: true, userInvocable: true },
	provider: PROVIDER_NAME,
	source: "bundled",
	resourceBase: RESOURCE_BASE,
	rank: BUNDLED_RANK,
	locator: SKILL_BODY_URL
};

const provider = {
	name: PROVIDER_NAME,
	list: () => Promise.resolve([CANDIDATE]),
	async get(_candidate) {
		return {
			name: CANDIDATE.name,
			description: CANDIDATE.description,
			invocation: CANDIDATE.invocation,
			provider: CANDIDATE.provider,
			source: CANDIDATE.source,
			resourceBase: RESOURCE_BASE,
			content: await readFile(SKILL_BODY_URL, "utf8")
		};
	}
};

/** Cordis plugin name. */
const name = "rvc-cover";
/** Service required by the bundled provider. */
const inject = ["skills"];

/**
 * Register the bundled `rvc-cover` provider on `ctx.skills`.
 * @param ctx - agent-scoped services.
 */
function apply(ctx) {
	ctx.skills.registerProvider(() => provider);
}

export { apply, inject, name };
