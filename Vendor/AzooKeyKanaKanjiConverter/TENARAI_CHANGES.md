# tenarai macOS vendor changes

Base: azooKey/AzooKeyKanaKanjiConverter ad714fea8cb2fe113aea86ba5c42563cdaf77cfb.
Preserve upstream license and dictionary licenses.

- llama.cpp binary moved from b4846 to azooKey b9637-azookey.1.
- Archive SHA256: 6176b3a6f7cbeca993644ca21d4b1c46ddaa59b98109376b7d32acef8e226a13 (GitHub release asset digest).
- `ZenzContext`: migrate flash_attn to flash_attn_type, KV cache API to llama_memory_seq_* with llama_get_memory.
- macOS uses ZenzaiCPU. The iOS repository is unchanged.

Do not upgrade without repeating the model, network-denial, API, and context scenario checks.

September 27 (reverted October 5): a raw-n run counter let "nn" + vowel share the
second n (konnichiwa -> こんにちわ). It made "hannei" read はんねい instead of the standard
はんえい (反映), so ComposingText is back to upstream: "nn" is ん
and ん followed by a na-row kana takes a third n (konnnichiha).

October 5 (personal language model): EfficientNGram compiled only under the `Zenzai`
trait, so the CPU build (`ZenzaiCPU`) used a mock with uniform probabilities and
personalization never worked; the condition now includes `ZenzaiCPU`. EfficientNGram is
exported as a library for training. Zenzai disabled its evaluation cache and the
pending-romaji deferral whenever personalization was on (Space p95 177 ms); the
personalization mode is now part of the evaluation cache key (PersonalizationMode is
Hashable) and deferral no longer depends on it (Space p95 32 ms at alpha 0.2).
bulkPredict results are memoized per (n-1)-token context (bounded).
