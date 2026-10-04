# 1B..brain..cells - GitHub Releases Harvester Worker

Bu depo, Orange..Cat evrensel Linux ekosisteminin **GitHub sürümleri ve varlıkları tarayıcı uydu işçisidir** (Worker Shard Producer).

## Lisans
Bu depo **GNU Affero General Public License v3.0 (AGPLv3)** ile lisanslanmıştır.

## İş Akışı ve Görevler
- **Zamanlanmış Tarama:** GitHub Actions üzerinden her 2 saatte bir (`0 */2 * * *`) otomatik olarak çalışır.
- **Sıfır İstemci İfşası:** GitHub API'si üzerinden genel FOSS sürümlerini tarar, mimari (x86_64, aarch64, armv7, riscv64) ve paket formatı analizi yapar.
- **Shard Çıktısı:** Üretilen `github_shard.db` dosyasını `latest` release etiketi altında yayınlayarak `sarman..kedi` ana veritabanına veri besler.
