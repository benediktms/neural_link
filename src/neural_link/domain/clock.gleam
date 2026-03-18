import birl.{type Time}

pub fn now() -> Time {
  birl.utc_now()
}

pub fn to_iso8601(time: Time) -> String {
  birl.to_iso8601(time)
}
