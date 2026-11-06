import { fileURLToPath } from "node:url"
import { createServer } from "node:http"
import { chromium } from "playwright"

const DEFAULT_LIMIT = 10
const MAX_LIMIT = 50
const MAX_BODY_BYTES = 64 * 1024
const NAVIGATION_TIMEOUT_MS = 30_000
const STATUS_TIMEOUT_MS = 20_000
const SEOUL_TIME_ZONE = "Asia/Seoul"
const PRE_OPEN_MINUTES = 30
const PRE_OPEN_CHECK_HOUR = 8
const DEFAULT_CHECK_INTERVAL_MINUTES = 60
const RETRY_INTERVALS_MINUTES = [15, 30, 60]
const DAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

export function extractNaverPlaceId(value) {
  try {
    const pathname = new URL(value).pathname
    return pathname.match(/\/place\/(\d+)/)?.[1] ?? null
  } catch {
    return null
  }
}

export function normalizeStatus(values) {
  return values.map((value) => value.trim()).filter(Boolean).at(-1) ?? null
}

export function parseLimit(value) {
  const limit = Number(value)
  if (!Number.isInteger(limit) || limit < 1) return DEFAULT_LIMIT
  return Math.min(limit, MAX_LIMIT)
}

export function parseTime(value) {
  const match = typeof value === "string" ? value.match(/^(\d{1,2}):(\d{2})$/) : null
  if (!match) return null
  const hour = Number(match[1])
  const minute = Number(match[2])
  if (hour > 24 || minute > 59 || (hour === 24 && minute !== 0)) return null
  return hour * 60 + minute
}

export function nextCheckAt({ now = new Date(), weekly, breakTimes = {}, intervalMinutes = DEFAULT_CHECK_INTERVAL_MINUTES }) {
  if (!weekly || Object.keys(weekly).length !== 7) {
    return { at: new Date(now.getTime() + intervalMinutes * 60_000), reason: "missing_schedule" }
  }

  const local = seoulParts(now)
  const today = new Date(Date.UTC(local.year, local.month - 1, local.day))
  const todayMinute = local.hour * 60 + local.minute

  for (let dayOffset = 0; dayOffset <= 7; dayOffset += 1) {
    const date = addDays(today, dayOffset)
    const dayKey = DAY_KEYS[date.getUTCDay()]
    const schedule = weekly[dayKey]
    if (dayOffset === 0) {
      const overnight = previousOvernightClose(weekly, dayKey)
      if (overnight !== null && todayMinute < overnight) {
        return { at: seoulDateAt(today, overnight), reason: "open" }
      }
    }
    if (!schedule || schedule.closed) continue

    const open = parseTime(schedule.open)
    const close = parseTime(schedule.close)
    if (open === null || close === null) continue

    if (dayOffset === 0) {
      const closeAbsolute = schedule.close_next_day && close <= open ? close + 24 * 60 : close
      if (todayMinute < PRE_OPEN_CHECK_HOUR * 60) {
        return { at: seoulDateAt(today, PRE_OPEN_CHECK_HOUR * 60), reason: "pre_open" }
      }
      if (todayMinute < open - PRE_OPEN_MINUTES) {
        return { at: seoulDateAt(today, open - PRE_OPEN_MINUTES), reason: "opening_soon" }
      }
      if (todayMinute < open) {
        return { at: seoulDateAt(today, open), reason: "opening" }
      }
      if (todayMinute >= closeAbsolute) continue

      const currentBreak = (breakTimes[dayKey] ?? []).map(normalizeBreak).find((item) => item && todayMinute >= item.start && todayMinute < item.end)
      if (currentBreak) return { at: seoulDateAt(today, currentBreak.end), reason: "break" }

      const nextBreak = (breakTimes[dayKey] ?? []).map(normalizeBreak).filter((item) => item && item.start > todayMinute).sort((a, b) => a.start - b.start)[0]
      const intervalAt = todayMinute + intervalMinutes
      if (nextBreak && nextBreak.start < Math.min(intervalAt, closeAbsolute)) {
        return { at: seoulDateAt(today, nextBreak.start), reason: "break_start" }
      }
      if (intervalAt < closeAbsolute) return { at: seoulDateAt(today, intervalAt), reason: "open" }
      return { at: seoulDateAt(today, closeAbsolute), reason: "closing" }
    }

    return { at: seoulDateAt(date, PRE_OPEN_CHECK_HOUR * 60), reason: "pre_open" }
  }

  return { at: new Date(now.getTime() + intervalMinutes * 60_000), reason: "missing_schedule" }
}

export function isPreOpenCheckWindow({ now = new Date(), weekly }) {
  if (!weekly) return false
  const local = seoulParts(now)
  const date = new Date(Date.UTC(local.year, local.month - 1, local.day))
  const schedule = weekly[DAY_KEYS[date.getUTCDay()]]
  const minute = local.hour * 60 + local.minute
  const open = parseTime(schedule?.open)
  return Boolean(schedule && !schedule.closed && open !== null && minute >= PRE_OPEN_CHECK_HOUR * 60 && minute < open)
}

function normalizeBreak(value) {
  const start = parseTime(value?.start)
  const end = parseTime(value?.end)
  return start === null || end === null ? null : { start, end: end <= start ? end + 24 * 60 : end }
}

function previousOvernightClose(weekly, dayKey) {
  const index = DAY_KEYS.indexOf(dayKey)
  const previous = weekly[DAY_KEYS[(index + 6) % 7]]
  if (!previous || previous.closed || !previous.close_next_day) return null
  const close = parseTime(previous.close)
  return close === null ? null : close
}

function seoulParts(date) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: SEOUL_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date)
  return Object.fromEntries(parts.filter(({ type }) => type !== "literal").map(({ type, value }) => [type, Number(value)]))
}

function addDays(date, amount) {
  const result = new Date(date)
  result.setUTCDate(result.getUTCDate() + amount)
  return result
}

function seoulDateAt(date, minute) {
  const dayOffset = Math.floor(minute / (24 * 60))
  const normalizedMinute = minute % (24 * 60)
  const target = addDays(date, dayOffset)
  return new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth(), target.getUTCDate(), 0, normalizedMinute, 0) - 9 * 60 * 60_000)
}

async function runBatch(limit) {
  const config = readConfig()
  const shops = await claimDueShops(config, limit)
  const results = []

  for (const shop of shops) {
    results.push(await processShop(config, shop))
  }

  return {
    requested: limit,
    selected: shops.length,
    succeeded: results.filter((result) => result.status !== null).length,
    failed: results.filter((result) => result.status === null).length,
    results,
  }
}

function readConfig() {
  const config = {
    supabaseUrl: process.env.SUPABASE_URL?.replace(/\/$/, ""),
    serviceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
    workerToken: process.env.WORKER_TOKEN,
  }
  if (!config.supabaseUrl || !config.serviceRoleKey || !config.workerToken) {
    throw new Error("SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, and WORKER_TOKEN are required")
  }
  return config
}

async function claimDueShops(config, limit) {
  return supabaseRequest(config, "/rest/v1/rpc/claim_due_shop_operating_statuses", {
    method: "POST",
    body: JSON.stringify({ batch_limit: limit }),
  })
}

export async function processShop(config, shop) {
  const sourceUrl = shop.naver_place_url
  const sourcePlaceId = typeof sourceUrl === "string" ? extractNaverPlaceId(sourceUrl) : null
  const checkedAt = new Date().toISOString()
  const intervalMinutes = DEFAULT_CHECK_INTERVAL_MINUTES

  try {
    const schedule = nextCheckAt({
      weekly: shop.business_hours_weekly,
      breakTimes: shop.business_hours_break_times,
      intervalMinutes,
    })
    if (schedule.reason !== "open" && schedule.reason !== "opening" && schedule.reason !== "closing" && !isPreOpenCheckWindow({ weekly: shop.business_hours_weekly })) {
      await updateSchedule(config, shop.id, {
        next_check_at: schedule.at.toISOString(),
        check_interval_minutes: intervalMinutes,
        check_reason: schedule.reason,
      })
      return { shop_id: String(shop.id), name: shop.name, status: "skipped", reason: schedule.reason }
    }
    if (typeof sourceUrl !== "string" || sourceUrl.trim() === "") {
      throw new Error("Invalid Naver place URL")
    }
    const browser = await chromium.launch({ headless: true })
    let scraped
    try {
      scraped = await scrapeShop(browser, sourceUrl, sourcePlaceId)
    } finally {
      await browser.close()
    }
    await upsertStatus(config, {
      shop_id: String(shop.id),
      naver_place_id: scraped.placeId,
      status: scraped.status,
      source_url: sourceUrl,
      checked_at: checkedAt,
      last_error: null,
      next_check_at: nextCheckAt({
        weekly: shop.business_hours_weekly,
        breakTimes: shop.business_hours_break_times,
        intervalMinutes,
      }).at.toISOString(),
      check_interval_minutes: intervalMinutes,
      check_reason: "open",
      consecutive_failures: 0,
    })
    return { shop_id: String(shop.id), name: shop.name, status: scraped.status }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    await upsertStatus(config, {
      shop_id: String(shop.id),
      naver_place_id: sourcePlaceId,
      source_url: sourceUrl ?? "",
      checked_at: checkedAt,
      last_error: message.slice(0, 500),
      next_check_at: new Date(Date.now() + retryMinutes(shop.consecutive_failures ?? 0) * 60_000).toISOString(),
      check_interval_minutes: retryMinutes(shop.consecutive_failures ?? 0),
      check_reason: "retry",
      consecutive_failures: (shop.consecutive_failures ?? 0) + 1,
    }).catch((upsertError) => console.error("Failed to persist crawl error", upsertError))
    return { shop_id: String(shop.id), name: shop.name, status: null, error: message }
  }
}

function retryMinutes(consecutiveFailures) {
  return RETRY_INTERVALS_MINUTES[Math.min(consecutiveFailures, RETRY_INTERVALS_MINUTES.length - 1)]
}

async function updateSchedule(config, shopId, record) {
  await supabaseRequest(config, `/rest/v1/shop_operating_status?shop_id=eq.${encodeURIComponent(shopId)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(record),
  })
}

async function scrapeShop(browser, sourceUrl, sourcePlaceId) {
  const page = await browser.newPage({ locale: "ko-KR", timezoneId: "Asia/Seoul" })
  page.setDefaultTimeout(STATUS_TIMEOUT_MS)

  try {
    await page.goto(sourcePlaceId ? `https://map.naver.com/p/entry/place/${sourcePlaceId}` : sourceUrl, {
      waitUntil: "domcontentloaded",
      timeout: NAVIGATION_TIMEOUT_MS,
    })
    const placeId = sourcePlaceId ?? extractNaverPlaceId(page.url())
    if (!placeId) throw new Error("Invalid Naver place URL")
    if (!sourcePlaceId) {
      await page.goto(`https://map.naver.com/p/entry/place/${placeId}`, {
        waitUntil: "domcontentloaded",
        timeout: NAVIGATION_TIMEOUT_MS,
      })
    }
    const frame = page.frameLocator("iframe#entryIframe")
    const primaryStatus = frame.locator("div.HzOD8.Mwr0n em.dtDQt")
    const fallbackStatus = frame.locator("em.dtDQt")
    const values = await readTexts(primaryStatus, fallbackStatus)
    const status = normalizeStatus(values)
    if (!status) throw new Error("Operating status was not found")

    const title = (await frame.locator("h1").first().textContent().catch(() => null))?.trim() || null
    return { placeId, title, status }
  } finally {
    await page.close()
  }
}

async function readTexts(primary, fallback) {
  try {
    await primary.first().waitFor({ state: "visible", timeout: STATUS_TIMEOUT_MS })
    const values = await primary.allTextContents()
    if (values.some((value) => value.trim() !== "")) return values
  } catch {
    // Naver can render the status with a different wrapper class.
  }
  await fallback.first().waitFor({ state: "visible", timeout: STATUS_TIMEOUT_MS })
  return fallback.allTextContents()
}

async function upsertStatus(config, record) {
  await supabaseRequest(config, "/rest/v1/shop_operating_status?on_conflict=shop_id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(record),
  })
}

async function supabaseRequest(config, path, options = {}) {
  const response = await fetch(`${config.supabaseUrl}${path}`, {
    ...options,
    headers: {
      apikey: config.serviceRoleKey,
      Authorization: `Bearer ${config.serviceRoleKey}`,
      "Content-Type": "application/json",
      ...options.headers,
    },
  })
  if (!response.ok) throw new Error(`Supabase request failed: ${response.status} ${await response.text()}`)
  const body = await response.text()
  return body === "" ? [] : JSON.parse(body)
}

export function createHttpServer() {
  return createServer(async (request, response) => {
    if (request.method === "GET" && request.url === "/health") return sendJson(response, 200, { ok: true })
    if (request.method !== "POST" || request.url !== "/run") return sendJson(response, 404, { error: "Not found" })

    const expectedToken = process.env.WORKER_TOKEN
    if (!expectedToken) return sendJson(response, 503, { error: "Worker is not configured" })
    if (request.headers.authorization !== `Bearer ${expectedToken}`) {
      return sendJson(response, 401, { error: "Unauthorized" })
    }

    try {
      const payload = await readJson(request)
      const result = await runBatch(parseLimit(payload?.limit))
      return sendJson(response, 200, result)
    } catch (error) {
      if (error instanceof RequestBodyError) {
        if (error.status === 413) response.setHeader("Connection", "close")
        return sendJson(response, error.status, { error: error.message })
      }
      console.error(error)
      return sendJson(response, 500, { error: error instanceof Error ? error.message : String(error) })
    }
  })
}

class RequestBodyError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let size = 0
    let chunks = []
    let tooLarge = false
    request.on("data", (chunk) => {
      if (tooLarge) return
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        tooLarge = true
        chunks = []
        reject(new RequestBodyError(413, "Request body is too large"))
        return
      }
      chunks.push(chunk)
    })
    request.on("end", () => {
      if (tooLarge) return
      const body = Buffer.concat(chunks, size).toString("utf8")
      if (body.trim() === "") return resolve({})
      let payload
      try {
        payload = JSON.parse(body)
      } catch {
        return reject(new RequestBodyError(400, "Invalid JSON"))
      }
      if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
        return reject(new RequestBodyError(400, "Request body must be a JSON object"))
      }
      resolve(payload)
    })
    request.on("error", reject)
  })
}

function sendJson(response, status, body) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" })
  response.end(JSON.stringify(body))
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const server = createHttpServer()
  server.listen(Number(process.env.PORT) || 8080, "0.0.0.0", () => {
    console.log(`Naver operating status worker listening on ${process.env.PORT || 8080}`)
  })
}
