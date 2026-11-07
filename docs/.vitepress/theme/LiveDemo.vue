<script setup lang="ts">
// A demo of examples/gallery/live_demos.zig, running in the page where the
// Markdown names it. Its slot is the page's picture of it: the poster until
// the demo runs, and what stays where it cannot. Nothing is fetched until it
// comes near the view, nor at all under the browser's data saver until asked.
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useData, withBase } from 'vitepress'

const props = withDefaults(defineProps<{ demo: string; source?: string; height?: number }>(), { height: 280, source: 'examples/gallery/live_demos.zig' })
const { isDark, lang } = useData()
const stage = ref<HTMLElement | null>(null)
const state = ref<'poster' | 'loading' | 'running' | 'failed'>('poster')
let host: any = null
let observer: IntersectionObserver | null = null
let gone = false

const saveData = () => (navigator as any).connection?.saveData === true

async function run() {
  if (state.value !== 'poster' && state.value !== 'failed') return
  state.value = 'loading'
  try {
    const { start } = await import(/* @vite-ignore */ withBase('/live/host.js'))
    const running = await start({
      wasm: withBase('/live/app.wasm'),
      fonts: withBase('/live/fonts/'),
      container: stage.value,
      args: ['app', `--demo=${props.demo}`],
      embed: true,
    })
    if (gone) return running.destroy()
    host = running
    // The poster goes once the first frame has been drawn.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!gone) state.value = 'running'
    }))
  } catch (e) {
    console.error(`myzig demo ${props.demo}:`, e)
    state.value = 'failed'
  }
}

// The host reads the page's appearance from this attribute.
const appearance = (dark: boolean) => {
  document.documentElement.dataset.myzigTheme = dark ? 'dark' : 'light'
}

onMounted(() => {
  appearance(isDark.value)
  if (saveData()) return
  observer = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return
    observer?.disconnect()
    run()
  }, { rootMargin: '200px' })
  if (stage.value) observer.observe(stage.value)
})

watch(isDark, appearance)

onBeforeUnmount(() => {
  gone = true
  observer?.disconnect()
  host?.destroy()
})
</script>

<template>
  <figure class="live-demo">
    <div ref="stage" class="live-demo-stage" :style="{ height: `${height}px` }">
      <div v-show="state !== 'running'" class="live-demo-poster"><slot /></div>
    </div>
    <figcaption class="live-demo-caption">
      <span v-if="state === 'failed'">
        {{ lang === 'vi' ? 'Không chạy được bản thử trong trình duyệt này.' : 'The demo could not start in this browser.' }}
      </span>
      <span v-else-if="state === 'loading'">{{ lang === 'vi' ? 'Đang tải…' : 'Loading…' }}</span>
      <a v-else-if="state === 'poster'" href="#" @click.prevent="run">{{ lang === 'vi' ? 'Chạy bản thử' : 'Run the demo' }}</a>
      <span v-else>{{ lang === 'vi' ? 'Đang chạy thật, bấm thử được: myzig trên WebAssembly' : 'Live, try it: myzig in WebAssembly' }}</span>
      <a :href="`https://github.com/hunghg255/myzig/blob/main/${props.source}`" target="_blank" rel="noreferrer">{{ lang === 'vi' ? 'Mã nguồn' : 'Source' }}</a>
    </figcaption>
  </figure>
</template>
