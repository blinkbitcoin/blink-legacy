// Exercises the real Redlock 5 `using()` lifecycle (acquire, automatic extension,
// abort, and the release in its finally block) against a scripted Redis client.
const mockEvalsha = jest.fn()

jest.mock("@/services/redis", () => ({
  redis: {
    evalsha: (...args: unknown[]) => mockEvalsha(...args),
    eval: jest.fn(),
  },
}))

jest.mock("@/config", () => ({ NETWORK: "regtest" }))

jest.mock("@/services/tracing", () => ({
  wrapAsyncFunctionsToRunInSpan: ({ fns }: { fns: unknown }) => fns,
}))

import {
  ResourceAttemptsRedlockServiceError,
  ResourceExpiredLockServiceError,
} from "@/domain/lock"
import { LockService } from "@/services/lock"

const quorumFailure =
  "The operation was unable to achieve a quorum during its retry window."

// Redis lock scripts return the number of keys they applied to: 1 is success.
const grantFirstCallOnly = () => {
  let calls = 0
  mockEvalsha.mockImplementation(async () => (++calls === 1 ? 1 : 0))
}

const settle = async <T>(promise: Promise<T>): Promise<T> => {
  // regtest: 10s lease, extension at 7.5s, 3 retries of 400ms +/- 200ms jitter.
  await jest.advanceTimersByTimeAsync(30_000)
  return promise
}

beforeEach(() => {
  jest.useFakeTimers()
  mockEvalsha.mockReset()
})

afterEach(() => {
  jest.useRealTimers()
})

it("keeps the routine's abort reason when Redlock's release fails after the lease is lost", async () => {
  grantFirstCallOnly()
  const routine = jest.fn(async (signal: RedlockAbortSignal) => {
    await new Promise((resolve) => signal.addEventListener("abort", resolve))
    return new ResourceExpiredLockServiceError(signal.error?.message)
  })

  const result = await settle(
    LockService().lockOnChainRebalance("receive", async (signal) => routine(signal)),
  )

  expect(routine).toHaveBeenCalledTimes(1)
  expect(result).toBeInstanceOf(ResourceExpiredLockServiceError)
  expect((result as Error).message).toBe(quorumFailure)
  // acquire + failed extensions + failed release attempts all reached Redis
  const releaseAttempts = mockEvalsha.mock.calls.filter(
    ([, , keysAndArgs]) => (keysAndArgs as unknown[]).length === 2,
  )
  expect(releaseAttempts.length).toBeGreaterThan(0)
})

it("reports a failed release after a successful routine with Redlock's reason", async () => {
  grantFirstCallOnly()

  const result = await settle(
    LockService().lockOnChainRebalance("receive", async () => true as const),
  )

  expect(result).toBeInstanceOf(ResourceAttemptsRedlockServiceError)
  expect((result as Error).message).toBe(quorumFailure)
})

it("reports exhausted acquisition with Redlock's reason without running the routine", async () => {
  mockEvalsha.mockResolvedValue(0)
  const routine = jest.fn(async () => true as const)

  const result = await settle(LockService().lockOnChainRebalance("receive", routine))

  expect(routine).not.toHaveBeenCalled()
  expect(result).toBeInstanceOf(ResourceAttemptsRedlockServiceError)
  expect((result as Error).message).toBe(quorumFailure)
  // regtest retryCount 3: one attempt plus three retries, then one cleanup release
  const acquireAttempts = mockEvalsha.mock.calls.filter(
    ([, , keysAndArgs]) => (keysAndArgs as unknown[]).length === 3,
  )
  expect(acquireAttempts).toHaveLength(4)
})

it("releases normally and returns the routine result when Redis cooperates", async () => {
  mockEvalsha.mockResolvedValue(1)

  const result = await settle(
    LockService().lockOnChainRebalance("receive", async () => "done"),
  )

  expect(result).toBe("done")
  expect(mockEvalsha.mock.calls.map(([, , keysAndArgs]) => keysAndArgs)).toEqual([
    ["locks:onchainrebalance:receive", expect.any(String), 10000],
    ["locks:onchainrebalance:receive", expect.any(String)],
  ])
})
