output "bucket" {
  value = module.remote_state.state_bucket.bucket
}

output "dynamodb_table" {
  value = module.remote_state.dynamodb_table.name
}

output "kms_key_id" {
  value = module.remote_state.kms_key.id
}
