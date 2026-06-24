# Job Registry

This file is the central workflow database mapping job ids to input files.

| Job ID | Job Code | File Name | Relative Path | Created At |
| --- | --- | --- | --- | --- |
| 0001 | J0001 | los_tres_cerditos.wav | data/input/los_tres_cerditos.wav | 2026-06-23 13:28:49 |
| 0002 | J0002 | mini_test_input.wav | data/input/mini_test_input.wav | 2026-06-23 13:28:49 |

## Step History

| Timestamp | Job ID | Job Code | Workflow Step | Status | Details |
| --- | --- | --- | --- | --- | --- |
| 2026-06-23 13:38:32 | 0002 | J0002 | 1-transcrever | STARTED | mini_test_input.wav |
| 2026-06-23 13:38:36 | 0002 | J0002 | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.srt |
| 2026-06-23 13:38:36 | 0002 | J0002 | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.srt |
| 2026-06-23 13:38:37 | 0002 | J0002 | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.pt.srt |
| 2026-06-23 13:38:37 | 0002 | J0002 | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.pt.srt |
| 2026-06-23 13:38:39 | 0002 | J0002 | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input_20260623_133837.wav |
| 2026-06-23 13:39:17 | 0002 | J0002 | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.srt |
| 2026-06-23 13:39:18 | 0002 | J0002 | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.pt.srt |
| 2026-06-23 13:39:28 | 0002 | J0002 | 1-transcrever | STARTED | mini_test_input.wav |
| 2026-06-23 13:46:56 | 0002 | J0002 | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.srt |
| 2026-06-23 13:46:56 | 0002 | J0002 | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.pt.srt |
| 2026-06-23 13:46:58 | 0002 | J0002 | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input_20260623_134656.wav |
| 2026-06-23 13:47:10 | 0002 | J0002 | 1-transcrever | STARTED | mini_test_input.wav |
| 2026-06-23 13:47:23 | 0002 | J0002 | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.srt |
| 2026-06-23 13:47:25 | 0002 | J0002 | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.pt.srt |
| 2026-06-23 13:47:28 | 0002 | J0002 | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input_20260623_134725.wav |
| 2026-06-23 13:47:48 | 0002 | J0002 | 1-transcrever | STARTED | mini_test_input.wav |
| 2026-06-23 13:47:59 | 0002 | J0002 | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.srt |
| 2026-06-23 13:48:00 | 0002 | J0002 | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.srt |
| 2026-06-23 13:48:01 | 0002 | J0002 | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.pt.srt |
| 2026-06-23 13:48:01 | 0002 | J0002 | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input.pt.srt |
| 2026-06-23 13:48:03 | 0002 | J0002 | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0002_mini-test-input_20260623_134801.wav |
| 0003 | J0003 | Ela se passou por uma criança de 8 anos, mas era um Gênio Milionário!.mp3 | data/input/Ela se passou por uma criança de 8 anos, mas era um Gênio Milionário!.mp3 | 2026-06-23 13:57:54 |
| 2026-06-23 13:57:59 | 0003 | J0003 | 1-transcrever | STARTED | Ela se passou por uma criança de 8 anos, mas era um Gênio Milionário!.mp3 |
| 2026-06-23 14:41:48 | e2e | E2E | 1-transcrever | STARTED | mini_test.wav |
| 2026-06-23 14:41:55 | e2e | E2E | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.srt |
| 2026-06-23 14:41:55 | e2e | E2E | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.srt |
| 2026-06-23 14:41:56 | e2e | E2E | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.pt.srt |
| 2026-06-23 14:41:56 | e2e | E2E | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.pt.srt |
| 2026-06-23 14:41:59 | e2e | E2E | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/output_20260623_144148.wav |
| 2026-06-23 14:51:19 | e2e | E2E | 1-transcrever | STARTED | mini_test.wav |
| 2026-06-23 14:51:25 | e2e | E2E | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.srt |
| 2026-06-23 14:51:25 | e2e | E2E | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.srt |
| 2026-06-23 14:51:26 | e2e | E2E | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.pt.srt |
| 2026-06-23 14:51:26 | e2e | E2E | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/audio_model.pt.srt |
| 2026-06-23 14:51:29 | e2e | E2E | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/output_20260623_145119.wav |
| 2026-06-23 15:08:40 | 0003 | J0003 | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0003_ela-se-passou-por-uma-criança-de-8-anos-mas-era-um-gênio-milionário.srt |
| 2026-06-23 15:09:22 | 0003 | J0003 | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0003_ela-se-passou-por-uma-criança-de-8-anos-mas-era-um-gênio-milionário.srt |
| 2026-06-23 15:55:51 | 0003 | J0003 | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0003_ela-se-passou-por-uma-criança-de-8-anos-mas-era-um-gênio-milionário.pt.srt |
| 2026-06-23 16:20:01 | 0003 | J0003 | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0003_ela-se-passou-por-uma-criança-de-8-anos-mas-era-um-gênio-milionário.pt.srt |
| 2026-06-23 18:08:39 | 0003 | J0003 | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0003_ela-se-passou-por-uma-criança-de-8-anos-mas-era-um-gênio-milionário_20260623_162001.wav |
| 2026-06-23 18:10:29 | e2e | E2E | 1-transcrever | STARTED | los_tres_cerditos.wav |
| 2026-06-23 18:18:18 | e2e | E2E | 1-transcrever | STARTED | los_tres_cerditos.wav |
| 2026-06-23 18:18:42 | e2e | E2E | 1-transcrever | SUCCESS | data/e2e/data/e2e/smoke-es.srt |
| 2026-06-23 18:20:23 | e2e | E2E | 1-transcrever | STARTED | los_tres_cerditos.wav |
| 2026-06-23 18:20:47 | e2e | E2E | 1-transcrever | SUCCESS | data/e2e/smoke-es.srt |
| 0004 | J0004 | e2e-test_chinese.mp3 | data/input/e2e-test_chinese.mp3 | 2026-06-23 18:42:10 |
| 0005 | J0005 | e2e-test_spanish.wav | data/input/e2e-test_spanish.wav | 2026-06-23 18:42:10 |
| 0006 | J0006 | 🔥【新番】末世大佬穿成穷媳妇,第一晚就把婆家粮缸吃空,破院改成药材仓库,把全村散户拧成一股绳,对抗盘踞多年走私团伙! audio 320 kbps original_chinese.mp3 | data/input/🔥【新番】末世大佬穿成穷媳妇,第一晚就把婆家粮缸吃空,破院改成药材仓库,把全村散户拧成一股绳,对抗盘踞多年走私团伙! audio 320 kbps original_chinese.mp3 | 2026-06-23 18:42:10 |
| 2026-06-23 18:42:10 | e2e | E2E | 1-transcrever | STARTED | e2e-test_spanish.wav |
| 2026-06-23 18:42:26 | e2e | E2E | 1-transcrever | SUCCESS | data/e2e/e2e-test_spanish_spanish.srt |
| 2026-06-23 18:42:33 | e2e | E2E | 2-traduzir | STARTED | data/e2e/e2e-test_spanish_spanish.srt |
| 2026-06-23 18:42:34 | e2e | E2E | 2-traduzir | SUCCESS | data/e2e/e2e-test_spanish_spanish.pt.srt |
| 2026-06-23 18:42:42 | e2e | E2E | 3-gerar-audiobook | STARTED | data/e2e/e2e-test_spanish_spanish.pt.srt |
| 2026-06-23 18:42:45 | e2e | E2E | 3-gerar-audiobook | SUCCESS | data/e2e/e2e-test_spanish_spanish.wav |
| 2026-06-23 18:42:54 | e2e | E2E | 1-transcrever | STARTED | e2e-test_chinese.mp3 |
| 2026-06-23 18:44:01 | e2e | E2E | 1-transcrever | SUCCESS | data/e2e/e2e-test_chinese_chinese.srt |
| 2026-06-23 18:44:12 | e2e | E2E | 2-traduzir | STARTED | data/e2e/e2e-test_chinese_chinese.srt |
| 2026-06-23 18:44:28 | e2e | E2E | 3-gerar-audiobook | STARTED | data/e2e/e2e-test_chinese_chinese.pt.srt |
| 2026-06-23 18:50:05 | e2e | E2E | 1-transcrever | STARTED | e2e-test_spanish.wav |
| 2026-06-23 18:50:23 | e2e | E2E | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-spanish_spanish.srt |
| 2026-06-23 18:50:23 | e2e | E2E | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-spanish_spanish.srt |
| 2026-06-23 18:50:24 | e2e | E2E | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-spanish_spanish.pt.srt |
| 2026-06-23 18:50:24 | e2e | E2E | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-spanish_spanish.pt.srt |
| 2026-06-23 18:50:27 | e2e | E2E | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-spanish_spanish.wav |
| 2026-06-23 18:50:27 | e2e | E2E | 1-transcrever | STARTED | e2e-test_chinese.mp3 |
| 2026-06-23 18:51:35 | e2e | E2E | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-chinese_chinese.srt |
| 2026-06-23 18:51:35 | e2e | E2E | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-chinese_chinese.srt |
| 2026-06-23 18:52:16 | e2e | E2E | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-chinese_chinese.pt.srt |
| 2026-06-23 18:52:16 | e2e | E2E | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-chinese_chinese.pt.srt |
| 2026-06-23 18:53:54 | e2e | E2E | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/e2e/e2e-test-chinese_chinese.wav |
| 0007 | J0007 | Ela se passou por uma criança de 8 anos, mas era um Gênio Milionário!.mp3 | data/input/archive/Ela se passou por uma criança de 8 anos, mas era um Gênio Milionário!.mp3 | 2026-06-23 18:57:51 |
| 2026-06-23 18:58:12 | 0006 | J0006 | 1-transcrever | STARTED | 🔥【新番】末世大佬穿成穷媳妇,第一晚就把婆家粮缸吃空,破院改成药材仓库,把全村散户拧成一股绳,对抗盘踞多年走私团伙! audio 320 kbps original_chinese.mp3 |
| 2026-06-23 19:50:46 | 0006 | J0006 | 1-transcrever | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0006_audio-320-kbps-original-chinese_chinese.srt |
| 2026-06-23 19:58:00 | 0006 | J0006 | 2-traduzir | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0006_audio-320-kbps-original-chinese_chinese.srt |
| 2026-06-23 21:00:24 | 0006 | J0006 | 2-traduzir | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0006_audio-320-kbps-original-chinese_chinese.pt.srt |
| 2026-06-23 21:08:13 | 0007 | J0007 | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0003_ela-se-passou-por-uma-criança-de-8-anos-mas-era-um-gênio-milionário.pt.srt |
| 2026-06-23 22:21:25 | 0006 | J0006 | 3-gerar-audiobook | STARTED | /home/sergio-vnt/audiobook-libs/data/outputs/job_0006_audio-320-kbps-original-chinese_chinese.pt.srt |
| 2026-06-23 23:45:19 | 0006 | J0006 | 3-gerar-audiobook | SUCCESS | /home/sergio-vnt/audiobook-libs/data/outputs/job_0006_audio-320-kbps-original-chinese_20260623_222125.wav |
| 0008 | J0008 | Bebé abandonada adoptada por los Zheng (7 hijos). Habla con animales; su manantial mágico cura video 720p spanish.mp4 | data/input/Bebé abandonada adoptada por los Zheng (7 hijos). Habla con animales; su manantial mágico cura video 720p spanish.mp4 | 2026-06-24 08:34:01 |
| 0009 | J0009 | ¡Huyendo del Desastre! Dos Hermanas Desfiguran su Rostro para Sobrevivir al Exilio video 720p spanish.mp4 | data/input/¡Huyendo del Desastre! Dos Hermanas Desfiguran su Rostro para Sobrevivir al Exilio video 720p spanish.mp4 | 2026-06-24 08:34:01 |
| 0010 | J0010 | ¡Mi Cocina Conecta al Mundo Moderno! Vendo Verduras Silvestres para Volverme Millonaria video 720p spanish.mp4 | data/input/¡Mi Cocina Conecta al Mundo Moderno! Vendo Verduras Silvestres para Volverme Millonaria video 720p spanish.mp4 | 2026-06-24 08:34:01 |
| 0011 | J0011 | ¡Reencarnó como una Chef Genio! El secreto de los fideos que salvó a su familia video 720p spanish.mp4 | data/input/¡Reencarnó como una Chef Genio! El secreto de los fideos que salvó a su familia video 720p spanish.mp4 | 2026-06-24 08:34:01 |
| 0012 | J0012 | Una Blogger de Comida Renace en la Pobreza- ¡Su Secreto para el Éxito! video 720p spanish.mp4 | data/input/Una Blogger de Comida Renace en la Pobreza- ¡Su Secreto para el Éxito! video 720p spanish.mp4 | 2026-06-24 08:34:01 |
| 0013 | J0013 | 《分家后我带四娃风生水起》【第1~82集】被嘲不孕凄惨分家,她转头带四个天才神娃逆袭暴富!#麻梨酥 #玄幻 #热血 #逆袭 #穿越 #爽文 #古装 #都市 video 720p english.mp4 | data/input/《分家后我带四娃风生水起》【第1~82集】被嘲不孕凄惨分家,她转头带四个天才神娃逆袭暴富!#麻梨酥 #玄幻 #热血 #逆袭 #穿越 #爽文 #古装 #都市 video 720p english.mp4 | 2026-06-24 08:34:01 |
