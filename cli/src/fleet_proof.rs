use sha2::{Digest, Sha256};

const HOST_PREFIX: &[u8] = b"tightbeam-host-set-v1\0";
const FLEET_PREFIX: &[u8] = b"tightbeam-fleet-proof-v1\0";
const TARGETS: [&str; 2] = ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct HostRow {
    pub name: String,
    pub ssh: Option<String>,
    pub base_dir: Option<String>,
    pub cli_bin: Option<String>,
    pub adapter_bin_dir: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct HostResult {
    pub name: String,
    pub target: String,
    pub release: String,
    pub build_commit: String,
    pub member_sha256: String,
    pub terminal_protocols: Vec<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FleetInput {
    pub manifest_sha256: String,
    pub terminal_protocols: Vec<u32>,
    pub release_transition_protocols: Vec<u32>,
    pub results: Vec<HostResult>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Receipt {
    pub bytes: Vec<u8>,
    pub sha256: String,
}

pub(crate) fn host_set(rows: &[HostRow]) -> Result<Receipt, &'static str> {
    canonical_host_rows(rows)?;
    let mut bytes = HOST_PREFIX.to_vec();
    push_u64(&mut bytes, rows.len())?;
    for row in rows {
        push_tagged(&mut bytes, Some(&row.name))?;
        push_tagged(&mut bytes, row.ssh.as_deref())?;
        push_tagged(&mut bytes, row.base_dir.as_deref())?;
        push_tagged(&mut bytes, row.cli_bin.as_deref())?;
        push_tagged(&mut bytes, row.adapter_bin_dir.as_deref())?;
    }
    Ok(receipt(bytes))
}

pub(crate) fn validate_host_set(bytes: &[u8]) -> Result<(), &'static str> {
    let mut cursor = Cursor::after_prefix(bytes, HOST_PREFIX)?;
    let count = cursor.bounded_count(13, "host row count exceeds bytes")?;
    let mut names = Vec::with_capacity(count);
    for _ in 0..count {
        names.push(cursor.tagged(false)?.ok_or("null host name")?);
        for _ in 0..4 {
            cursor.tagged(true)?;
        }
    }
    cursor.finished()?;
    canonical_names(&names)
}

pub(crate) fn fleet_proof(hosts: &[HostRow], input: &FleetInput) -> Result<Receipt, &'static str> {
    let host_receipt = host_set(hosts)?;
    lower_hex(&input.manifest_sha256, 64, "invalid manifest sha256")?;
    canonical_protocols(&input.terminal_protocols)?;
    canonical_protocols(&input.release_transition_protocols)?;
    matching_results(hosts, &input.results)?;

    let mut bytes = FLEET_PREFIX.to_vec();
    push_tagged(&mut bytes, Some(&host_receipt.sha256))?;
    push_tagged(&mut bytes, Some(&input.manifest_sha256))?;
    push_protocols(&mut bytes, &input.terminal_protocols)?;
    push_protocols(&mut bytes, &input.release_transition_protocols)?;
    push_u64(&mut bytes, input.results.len())?;
    for result in &input.results {
        push_tagged(&mut bytes, Some(&result.name))?;
        push_tagged(&mut bytes, Some(&result.target))?;
        push_tagged(&mut bytes, Some(&result.release))?;
        push_tagged(&mut bytes, Some(&result.build_commit))?;
        push_tagged(&mut bytes, Some(&result.member_sha256))?;
        push_protocols(&mut bytes, &result.terminal_protocols)?;
    }
    Ok(receipt(bytes))
}

pub(crate) fn validate_fleet_proof(bytes: &[u8], hosts: &[HostRow]) -> Result<(), &'static str> {
    let host_receipt = host_set(hosts)?;
    let mut cursor = Cursor::after_prefix(bytes, FLEET_PREFIX)?;
    let host_sha = cursor.tagged(false)?.ok_or("null host sha256")?;
    if host_sha != host_receipt.sha256 {
        return Err("host set mismatch");
    }
    let manifest_sha = cursor.tagged(false)?.ok_or("null manifest sha256")?;
    lower_hex(&manifest_sha, 64, "invalid manifest sha256")?;
    cursor.protocols()?;
    cursor.protocols()?;
    let count = cursor.bounded_count(53, "host result count exceeds bytes")?;
    if count != hosts.len() {
        return Err("host result count mismatch");
    }
    let mut results = Vec::with_capacity(count);
    for _ in 0..count {
        let name = cursor.tagged(false)?.ok_or("null result name")?;
        let target = cursor.tagged(false)?.ok_or("null target")?;
        let release = cursor.tagged(false)?.ok_or("null release")?;
        let build_commit = cursor.tagged(false)?.ok_or("null build commit")?;
        let member_sha256 = cursor.tagged(false)?.ok_or("null member sha256")?;
        let terminal_protocols = cursor.protocols()?;
        results.push(HostResult {
            name,
            target,
            release,
            build_commit,
            member_sha256,
            terminal_protocols,
        });
    }
    cursor.finished()?;
    matching_results(hosts, &results)
}

fn matching_results(hosts: &[HostRow], results: &[HostResult]) -> Result<(), &'static str> {
    canonical_host_rows(hosts)?;
    let names: Vec<&str> = results.iter().map(|row| row.name.as_str()).collect();
    canonical_names(&names)?;
    if hosts
        .iter()
        .map(|host| host.name.as_str())
        .ne(results.iter().map(|result| result.name.as_str()))
    {
        return Err("host result mismatch");
    }
    for result in results {
        if !TARGETS.contains(&result.target.as_str()) {
            return Err("invalid target");
        }
        if !valid_release(&result.release) {
            return Err("invalid release");
        }
        lower_hex(&result.build_commit, 40, "invalid build commit")?;
        lower_hex(&result.member_sha256, 64, "invalid member sha256")?;
        canonical_protocols(&result.terminal_protocols)?;
    }
    Ok(())
}

fn canonical_host_rows(rows: &[HostRow]) -> Result<(), &'static str> {
    let names: Vec<&str> = rows.iter().map(|row| row.name.as_str()).collect();
    canonical_names(&names)
}

fn canonical_names<T: AsRef<str>>(names: &[T]) -> Result<(), &'static str> {
    for pair in names.windows(2) {
        match pair[0].as_ref().as_bytes().cmp(pair[1].as_ref().as_bytes()) {
            std::cmp::Ordering::Less => {}
            std::cmp::Ordering::Equal => return Err("duplicate host name"),
            std::cmp::Ordering::Greater => return Err("noncanonical host order"),
        }
    }
    Ok(())
}

fn canonical_protocols(values: &[u32]) -> Result<(), &'static str> {
    for pair in values.windows(2) {
        match pair[0].cmp(&pair[1]) {
            std::cmp::Ordering::Less => {}
            std::cmp::Ordering::Equal => return Err("duplicate protocol"),
            std::cmp::Ordering::Greater => return Err("noncanonical protocol order"),
        }
    }
    Ok(())
}

fn push_protocols(bytes: &mut Vec<u8>, values: &[u32]) -> Result<(), &'static str> {
    canonical_protocols(values)?;
    push_u64(bytes, values.len())?;
    for value in values {
        bytes.extend_from_slice(&value.to_be_bytes());
    }
    Ok(())
}

fn push_tagged(bytes: &mut Vec<u8>, value: Option<&str>) -> Result<(), &'static str> {
    match value {
        None => bytes.push(0),
        Some(value) => {
            bytes.push(1);
            push_u64(bytes, value.len())?;
            bytes.extend_from_slice(value.as_bytes());
        }
    }
    Ok(())
}

fn push_u64(bytes: &mut Vec<u8>, value: usize) -> Result<(), &'static str> {
    let value = u64::try_from(value).map_err(|_| "count exceeds u64")?;
    bytes.extend_from_slice(&value.to_be_bytes());
    Ok(())
}

fn lower_hex(value: &str, length: usize, error: &'static str) -> Result<(), &'static str> {
    if value.len() == length
        && value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        Ok(())
    } else {
        Err(error)
    }
}

fn valid_release(value: &str) -> bool {
    let (version, build) = value
        .split_once('+')
        .map_or((value, None), |(version, build)| (version, Some(build)));
    if build.is_some_and(|build| !valid_identifiers(build, false)) {
        return false;
    }

    let (core, prerelease) = version
        .split_once('-')
        .map_or((version, None), |(core, prerelease)| {
            (core, Some(prerelease))
        });
    if prerelease.is_some_and(|prerelease| !valid_identifiers(prerelease, true)) {
        return false;
    }

    let parts: Vec<&str> = core.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|part| !part.is_empty() && (*part == "0" || !part.starts_with('0')))
        && parts
            .iter()
            .all(|part| part.as_bytes().iter().all(u8::is_ascii_digit))
}

fn valid_identifiers(value: &str, reject_numeric_leading_zero: bool) -> bool {
    !value.is_empty()
        && value.split('.').all(|identifier| {
            !identifier.is_empty()
                && identifier
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                && (!reject_numeric_leading_zero
                    || !identifier.bytes().all(|byte| byte.is_ascii_digit())
                    || identifier == "0"
                    || !identifier.starts_with('0'))
        })
}

fn receipt(bytes: Vec<u8>) -> Receipt {
    Receipt {
        sha256: format!("{:x}", Sha256::digest(&bytes)),
        bytes,
    }
}

struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn after_prefix(bytes: &'a [u8], prefix: &[u8]) -> Result<Self, &'static str> {
        if !bytes.starts_with(prefix) {
            return Err("invalid prefix");
        }
        Ok(Self {
            bytes,
            offset: prefix.len(),
        })
    }

    fn u64_as_usize(&mut self) -> Result<usize, &'static str> {
        let raw = self.take(8)?;
        let value = u64::from_be_bytes(raw.try_into().map_err(|_| "truncated count")?);
        usize::try_from(value).map_err(|_| "count exceeds usize")
    }

    fn bounded_count(
        &mut self,
        minimum_item_bytes: usize,
        error: &'static str,
    ) -> Result<usize, &'static str> {
        let count = self.u64_as_usize()?;
        if count > (self.bytes.len() - self.offset) / minimum_item_bytes {
            return Err(error);
        }
        Ok(count)
    }

    fn u32(&mut self) -> Result<u32, &'static str> {
        let raw = self.take(4)?;
        Ok(u32::from_be_bytes(
            raw.try_into().map_err(|_| "truncated protocol")?,
        ))
    }

    fn tagged(&mut self, nullable: bool) -> Result<Option<String>, &'static str> {
        let tag = *self.take(1)?.first().ok_or("truncated tag")?;
        match tag {
            0 if nullable => Ok(None),
            0 => Err("null not allowed"),
            1 => {
                let length = self.u64_as_usize()?;
                let value = self.take(length)?;
                Ok(Some(
                    std::str::from_utf8(value)
                        .map_err(|_| "invalid utf8")?
                        .to_owned(),
                ))
            }
            _ => Err("invalid tag"),
        }
    }

    fn protocols(&mut self) -> Result<Vec<u32>, &'static str> {
        let count = self.bounded_count(4, "protocol count exceeds bytes")?;
        let mut values = Vec::with_capacity(count);
        for _ in 0..count {
            values.push(self.u32()?);
        }
        canonical_protocols(&values)?;
        Ok(values)
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], &'static str> {
        let end = self.offset.checked_add(length).ok_or("length overflow")?;
        let value = self.bytes.get(self.offset..end).ok_or("truncated bytes")?;
        self.offset = end;
        Ok(value)
    }

    fn finished(&self) -> Result<(), &'static str> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err("trailing bytes")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../test/fixtures/client-fleet-proof-v1.json"
        ))
        .expect("shared fleet-proof fixture parses")
    }

    fn hosts(vector: &Value) -> Vec<HostRow> {
        vector["hosts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| HostRow {
                name: string(row, "name"),
                ssh: optional_string(row, "ssh"),
                base_dir: optional_string(row, "baseDir"),
                cli_bin: optional_string(row, "cliBin"),
                adapter_bin_dir: optional_string(row, "adapterBinDir"),
            })
            .collect()
    }

    fn fleet_input(vector: &Value) -> FleetInput {
        FleetInput {
            manifest_sha256: string(vector, "manifestSha256"),
            terminal_protocols: protocols(vector, "terminalProtocols"),
            release_transition_protocols: protocols(vector, "releaseTransitionProtocols"),
            results: vector["results"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| HostResult {
                    name: string(row, "name"),
                    target: string(row, "target"),
                    release: string(row, "release"),
                    build_commit: string(row, "buildCommit"),
                    member_sha256: string(row, "memberSha256"),
                    terminal_protocols: protocols(row, "terminalProtocols"),
                })
                .collect(),
        }
    }

    fn string(value: &Value, key: &str) -> String {
        value[key].as_str().unwrap().to_owned()
    }

    fn optional_string(value: &Value, key: &str) -> Option<String> {
        value[key].as_str().map(ToOwned::to_owned)
    }

    fn protocols(value: &Value, key: &str) -> Vec<u32> {
        value[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| u32::try_from(item.as_u64().unwrap()).unwrap())
            .collect()
    }

    fn decode_hex(value: &str) -> Vec<u8> {
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect()
    }

    #[test]
    fn shared_literal_vectors_match_and_validate() {
        let fixture = fixture();
        assert_eq!(fixture["schema"], "tightbeam-client-fleet-proof-fixture/v1");
        for vector in fixture["vectors"].as_array().unwrap() {
            let hosts = hosts(vector);
            let host = host_set(&hosts).unwrap();
            assert_eq!(
                host.bytes,
                decode_hex(vector["hostSetHex"].as_str().unwrap())
            );
            assert_eq!(host.sha256, vector["hostSetSha256"]);
            validate_host_set(&host.bytes).unwrap();

            let fleet = fleet_proof(&hosts, &fleet_input(vector)).unwrap();
            assert_eq!(
                fleet.bytes,
                decode_hex(vector["fleetProofHex"].as_str().unwrap())
            );
            assert_eq!(fleet.sha256, vector["fleetProofSha256"]);
            validate_fleet_proof(&fleet.bytes, &hosts).unwrap();
        }
    }

    #[test]
    fn structured_inputs_refuse_noncanonical_rows_fields_and_protocols() {
        let fixture = fixture();
        let vector = &fixture["vectors"].as_array().unwrap().last().unwrap();
        let mut reversed_hosts = hosts(vector);
        reversed_hosts.reverse();
        assert!(host_set(&reversed_hosts).is_err());

        let hosts = hosts(vector);
        let mut input = fleet_input(vector);
        input.results.reverse();
        assert!(fleet_proof(&hosts, &input).is_err());
        let mut input = fleet_input(vector);
        input.terminal_protocols = vec![2, 1];
        assert!(fleet_proof(&hosts, &input).is_err());
        input.terminal_protocols = vec![1, 1];
        assert!(fleet_proof(&hosts, &input).is_err());
        input.terminal_protocols = vec![1];
        input.manifest_sha256 = "A".repeat(64);
        assert!(fleet_proof(&hosts, &input).is_err());
        input.manifest_sha256 = "a".repeat(64);
        input.results[0].release = "1.2.3-!".to_owned();
        assert!(fleet_proof(&hosts, &input).is_err());
        input = fleet_input(vector);
        input.results.pop();
        assert!(fleet_proof(&hosts, &input).is_err());
    }

    #[test]
    fn byte_validators_refuse_every_structural_band_and_one_bit_changes_the_digest() {
        let fixture = fixture();
        let vector = fixture["vectors"].as_array().unwrap().last().unwrap();
        let hosts = hosts(vector);
        let host = host_set(&hosts).unwrap();
        let fleet = fleet_proof(&hosts, &fleet_input(vector)).unwrap();

        for index in [0, HOST_PREFIX.len(), HOST_PREFIX.len() + 8] {
            let mut mutated = host.bytes.clone();
            mutated[index] ^= 1;
            assert!(validate_host_set(&mutated).is_err());
        }
        for index in [0, FLEET_PREFIX.len(), FLEET_PREFIX.len() + 8] {
            let mut mutated = fleet.bytes.clone();
            mutated[index] ^= 1;
            assert!(validate_fleet_proof(&mutated, &hosts).is_err());
        }
        let mut payload_mutation = fleet.bytes.clone();
        let last = payload_mutation.len() - 1;
        payload_mutation[last] ^= 1;
        assert_ne!(receipt(payload_mutation.clone()).sha256, fleet.sha256);

        let mut trailing = fleet.bytes.clone();
        trailing.push(0);
        assert!(validate_fleet_proof(&trailing, &hosts).is_err());
        for length in 0..fleet.bytes.len() {
            assert!(validate_fleet_proof(&fleet.bytes[..length], &hosts).is_err());
        }
    }
}
