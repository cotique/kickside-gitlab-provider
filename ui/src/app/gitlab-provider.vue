<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api } from '@wippy-fe/proxy'
import { Icon } from '@iconify/vue'

// GitLab Connector page: shows the module identity for the gitlab-provider
// connection/pull-source module, from GET /api/v1/gitlab-provider/status.
// The module persists no rows of its own (Data Sync's engine owns cursor,
// lease, schedule, dedup, id-map, and sink routing), so there is no count to
// show here — see BUILD-NOTES.md.
interface Status {
  module: string
  status: string
  provider: string
}

const status = ref<Status | null>(null)
const loading = ref(true)
const error = ref('')

async function load() {
  loading.value = true
  error.value = ''
  try {
    const { data } = await api.get('/api/v1/gitlab-provider/status')
    if (!data?.success) throw new Error(data?.error || 'Could not load gitlab-provider status.')
    status.value = { module: String(data.module), status: String(data.status), provider: String(data.provider) }
  } catch (e) {
    status.value = null
    error.value = e instanceof Error ? e.message : 'Could not load gitlab-provider status.'
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="st">
    <div class="st-head">
      <div class="st-head-icon"><Icon icon="tabler:brand-gitlab" /></div>
      <div>
        <h1 class="st-title">{{ status?.module ?? 'cotique/gitlab-provider' }}</h1>
        <p class="st-sub">GitLab connection provider and merge-request pull source for Kickside Data Sync.</p>
      </div>
    </div>

    <div v-if="loading" class="st-state">Loading…</div>
    <div v-else-if="error" class="st-state st-error">
      {{ error }}
      <button class="st-retry" type="button" @click="load">Retry</button>
    </div>
    <div v-else class="st-body">
      <div class="st-card">
        <span class="st-count">{{ status?.status ?? 'unknown' }}</span>
        <span class="st-count-label">module status</span>
      </div>
    </div>
  </div>
</template>
