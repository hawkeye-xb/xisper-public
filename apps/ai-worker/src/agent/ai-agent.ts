import { DurableObject } from 'cloudflare:workers'

interface ProviderHealth {
  lastFailure?: number
  consecutiveFailures: number
  lastSuccess?: number
}

export class AIAgent extends DurableObject {
  private providers: Record<string, ProviderHealth> = {}

  async recordSuccess(providerName: string) {
    this.providers[providerName] = {
      ...this.providers[providerName],
      consecutiveFailures: 0,
      lastSuccess: Date.now(),
    }
  }

  async recordFailure(providerName: string) {
    const current = this.providers[providerName] || { consecutiveFailures: 0 }
    this.providers[providerName] = {
      ...current,
      consecutiveFailures: current.consecutiveFailures + 1,
      lastFailure: Date.now(),
    }
  }

  async getProviderHealth(providerName: string): Promise<ProviderHealth> {
    return this.providers[providerName] || { consecutiveFailures: 0 }
  }

  async getAllHealth(): Promise<Record<string, ProviderHealth>> {
    return this.providers
  }
}
