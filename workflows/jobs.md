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
