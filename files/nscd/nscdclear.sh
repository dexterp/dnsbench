#!/bin/bash

sleep $((RANDOM % 600))
nscd -i hosts
