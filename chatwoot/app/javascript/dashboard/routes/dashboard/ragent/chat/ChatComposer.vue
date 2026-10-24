<script setup>
import { computed, onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  sending: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  readOnly: { type: Boolean, default: false },
});
const emit = defineEmits(['send', 'stop']);

const { t } = useI18n();

const MAX_FILE_BYTES = 25 * 1024 * 1024;
const MAX_FILES = 10;

const draft = ref('');
const files = ref([]);
const picker = ref(null);
const dictating = ref(false);
let recognition = null;
let localTranscriber = null;
let localTranscriberPromise = null;

const canSend = computed(
  () =>
    !props.disabled &&
    !props.sending &&
    (draft.value.trim() || files.value.length > 0)
);

const sameFile = (a, b) =>
  a.name === b.name && a.size === b.size && a.lastModified === b.lastModified;

const addFiles = list => {
  Array.from(list || []).forEach(file => {
    if (file.size > MAX_FILE_BYTES) {
      useAlert(t('RAGENT.CHAT.ATTACH_TOO_BIG', { name: file.name }));
      return;
    }
    if (files.value.some(f => sameFile(f, file))) return;
    if (files.value.length >= MAX_FILES) {
      useAlert(t('RAGENT.CHAT.ATTACH_LIMIT', { n: MAX_FILES }));
      return;
    }
    files.value.push(file);
  });
};

const onPick = event => {
  addFiles(event.target.files);
  // permite escolher o mesmo arquivo de novo depois de remover
  event.target.value = '';
};

const onDrop = event => {
  if (!props.readOnly && !props.sending) addFiles(event.dataTransfer.files);
};

// Spec 12 §5: privacidade e latência primeiro. Chrome/Edge transcrevem o
// ditado diretamente no navegador; nenhum áudio é enviado à LUAR nesse fluxo.
const startBrowserDictation = () => {
  const Recognition =
    window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Recognition) return false;

  const initialDraft = draft.value;
  recognition = new Recognition();
  recognition.lang = 'pt-BR';
  recognition.continuous = false;
  recognition.interimResults = true;
  recognition.onstart = () => {
    dictating.value = true;
  };
  recognition.onresult = event => {
    let transcript = '';
    for (let i = event.resultIndex; i < event.results.length; i += 1)
      transcript += event.results[i][0].transcript;
    draft.value = [initialDraft, transcript.trim()]
      .filter(Boolean)
      .join(initialDraft && transcript ? ' ' : '');
  };
  recognition.onerror = event => {
    if (event.error !== 'aborted') useAlert(t('RAGENT.CHAT.DICTATION_ERROR'));
  };
  recognition.onend = () => {
    dictating.value = false;
    recognition = null;
  };
  recognition.start();
  return true;
};

const stopBrowserDictation = () => recognition?.stop();

// Spec 12 §5: quando Web Speech não existe, a frase segue para Whisper WASM/WebGPU
// no próprio browser. Áudio nunca vai para o motor nem consome GPU da VPS.
const recording = ref(false);
const seconds = ref(0);
let recorder = null;
let timer = null;
let chunks = [];
const MAX_SECONDS = 600;

const stopTimer = () => {
  clearInterval(timer);
  timer = null;
};

const transcribing = ref(false);

const browserAudio = async file => {
  const Context = window.AudioContext || window.webkitAudioContext;
  if (!Context || !window.OfflineAudioContext)
    throw new Error('audio-context-unsupported');

  const context = new Context();
  try {
    const decoded = await context.decodeAudioData(await file.arrayBuffer());
    const sampleRate = 16_000;
    const offline = new OfflineAudioContext(
      1,
      Math.ceil(decoded.duration * sampleRate),
      sampleRate
    );
    const source = offline.createBufferSource();
    source.buffer = decoded;
    source.connect(offline.destination);
    source.start();
    return (await offline.startRendering()).getChannelData(0);
  } finally {
    await context.close();
  }
};

const loadLocalTranscriber = async () => {
  if (localTranscriber) return localTranscriber;
  if (!localTranscriberPromise) {
    localTranscriberPromise = import('@huggingface/transformers').then(
      async ({ env, pipeline }) => {
        // O artefato do modelo fica no Cache Storage do navegador após o primeiro uso.
        // Só pesos são baixados; amostras de áudio não saem do dispositivo.
        env.useBrowserCache = true;
        localTranscriber = await pipeline(
          'automatic-speech-recognition',
          'Xenova/whisper-tiny',
          { device: 'wasm' }
        );
        return localTranscriber;
      }
    );
  }
  return localTranscriberPromise;
};

const dictateLocally = async file => {
  transcribing.value = true;
  try {
    const [transcribe, samples] = await Promise.all([
      loadLocalTranscriber(),
      browserAudio(file),
    ]);
    const result = await transcribe(samples, {
      language: 'portuguese',
      task: 'transcribe',
    });
    const text = result?.text?.trim();
    if (!text) throw new Error('empty-transcript');
    draft.value = draft.value ? `${draft.value} ${text}` : text;
  } catch (error) {
    useAlert(t('RAGENT.CHAT.DICTATION_ERROR'));
  } finally {
    transcribing.value = false;
  }
};

const stopRecording = (cancel = false) => {
  stopTimer();
  recording.value = false;
  if (recorder && recorder.state !== 'inactive') {
    recorder.cancelled = cancel === true;
    recorder.stop();
  }
};

const startRecording = async () => {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    chunks = [];
    const mime = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
      ? 'audio/webm;codecs=opus'
      : 'audio/mp4';
    recorder = new MediaRecorder(stream, { mimeType: mime });
    recorder.ondataavailable = e => e.data.size && chunks.push(e.data);
    recorder.onstop = () => {
      stream.getTracks().forEach(tr => tr.stop());
      if (recorder.cancelled) return;
      const ext = mime.startsWith('audio/mp4') ? 'm4a' : 'webm';
      const file = new File(
        [new Blob(chunks, { type: mime })],
        `voz-${Date.now()}.${ext}`,
        {
          type: mime,
        }
      );
      dictateLocally(file);
    };
    recorder.start();
    recording.value = true;
    seconds.value = 0;
    timer = setInterval(() => {
      seconds.value += 1;
      if (seconds.value >= MAX_SECONDS) stopRecording();
    }, 1000);
  } catch (error) {
    useAlert(t('RAGENT.CHAT.MIC_DENIED'));
  }
};

const startDictation = () => {
  if (!startBrowserDictation()) startRecording();
};

onBeforeUnmount(() => {
  stopBrowserDictation();
  stopRecording(true);
});

const timeLabel = computed(
  () =>
    `${String(Math.floor(seconds.value / 60)).padStart(2, '0')}:${String(seconds.value % 60).padStart(2, '0')}`
);

const removeFile = index => files.value.splice(index, 1);

const formatSize = bytes => {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
};

const submit = () => {
  if (!canSend.value) return;
  emit('send', { text: draft.value.trim(), files: files.value.slice() });
  draft.value = '';
  files.value = [];
};
</script>

<template>
  <footer
    class="flex flex-col gap-2 border-t border-n-weak p-3 max-md:ps-20"
    @dragover.prevent
    @drop.prevent="onDrop"
  >
    <p v-if="readOnly" class="text-body-main text-n-slate-11">
      {{ t('RAGENT.CHAT.READ_ONLY') }}
    </p>
    <template v-else>
      <ul v-if="files.length" class="flex flex-wrap gap-2">
        <li
          v-for="(file, i) in files"
          :key="`${file.name}-${file.size}-${file.lastModified}`"
          class="flex max-w-full items-center gap-2 rounded-lg bg-n-alpha-2 px-2 py-1 text-body-main text-n-slate-12"
        >
          <span class="i-lucide-paperclip size-4 shrink-0" aria-hidden="true" />
          <span class="truncate">{{ file.name }}</span>
          <span class="shrink-0 text-n-slate-11">
            {{ formatSize(file.size) }}
          </span>
          <button
            type="button"
            class="shrink-0 text-n-slate-11 hover:text-n-slate-12"
            :aria-label="t('RAGENT.CHAT.ATTACH_REMOVE', { name: file.name })"
            :disabled="sending"
            @click="removeFile(i)"
          >
            <span class="i-lucide-x size-4" aria-hidden="true" />
          </button>
        </li>
      </ul>
      <div class="flex items-end gap-2">
        <input
          ref="picker"
          type="file"
          multiple
          class="hidden"
          data-testid="chat-file-input"
          @change="onPick"
        />
        <Button
          icon="i-lucide-paperclip"
          variant="ghost"
          color="slate"
          :title="t('RAGENT.CHAT.ATTACH')"
          :aria-label="t('RAGENT.CHAT.ATTACH')"
          :disabled="sending || disabled"
          @click="picker.click()"
        />
        <Button
          v-if="!recording && !dictating"
          icon="i-lucide-mic"
          variant="ghost"
          color="slate"
          :title="t('RAGENT.CHAT.MIC')"
          :aria-label="t('RAGENT.CHAT.MIC')"
          :disabled="sending || disabled"
          @click="startDictation"
        />
        <div
          v-else-if="dictating"
          class="flex items-center gap-2 text-body-main text-n-ruby-11"
        >
          <span
            class="size-2 rounded-full bg-n-ruby-9 animate-pulse"
            aria-hidden="true"
          />
          {{ t('RAGENT.CHAT.DICTATING') }}
          <Button
            :label="t('RAGENT.CHAT.MIC_DONE')"
            size="sm"
            @click="stopBrowserDictation"
          />
        </div>
        <div
          v-else-if="transcribing"
          class="flex items-center gap-2 text-body-main text-n-slate-11"
        >
          <span
            class="i-lucide-loader-circle size-4 animate-spin"
            aria-hidden="true"
          />
          {{ t('RAGENT.CHAT.TRANSCRIBING_LOCAL') }}
        </div>
        <div
          v-else
          class="flex items-center gap-2 text-body-main text-n-ruby-11"
        >
          <span
            class="size-2 rounded-full bg-n-ruby-9 animate-pulse"
            aria-hidden="true"
          />
          {{ timeLabel }}
          <Button
            :label="t('RAGENT.CHAT.MIC_DONE')"
            size="sm"
            @click="stopRecording(false)"
          />
          <Button
            :label="t('RAGENT.CHAT.MIC_CANCEL')"
            size="sm"
            variant="ghost"
            color="slate"
            @click="stopRecording(true)"
          />
        </div>
        <textarea
          v-model="draft"
          rows="2"
          class="!mb-0 flex-1 resize-none"
          :placeholder="t('RAGENT.CHAT.PLACEHOLDER')"
          :disabled="sending"
          @keydown.enter.exact.prevent="submit"
        />
        <Button
          v-if="!sending"
          :label="t('RAGENT.CHAT.SEND')"
          :disabled="!canSend"
          @click="submit"
        />
        <Button
          v-else
          :label="t('RAGENT.CHAT.STOP')"
          color="ruby"
          @click="emit('stop')"
        />
      </div>
    </template>
  </footer>
</template>
