data "aws_availability_zones" "available" {}

locals {
  vpc_cidr = "10.0.0.0/16"
  azs = slice(data.aws_availability_zones.available.names, 0, var.azs_count)
  container_port = 80
  container_name = "wordpress"
  db_name = "limble"
  db_user = "limble"
  db_password = "limblepassword" # because demo
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name = var.name
  cidr = local.vpc_cidr
  azs = local.azs
  public_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 3)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 6)]
  enable_nat_gateway = true
  single_nat_gateway = true
}

module "rds" {
  source = "terraform-aws-modules/rds/aws"
  identifier = var.name
  engine = "mysql"
  engine_version = "8.0"
  family = "mysql8.0"
  major_engine_version = "8.0"
  instance_class = "db.t4g.micro"
  allocated_storage = 20
  max_allocated_storage = 100
  multi_az = true
  db_subnet_group_name = module.vpc.database_subnet_group

  # because demo
  apply_immediately = true
  skip_final_snapshot = true
  db_name = local.db_name
  username = local.db_user
  manage_master_user_password = false
  password = local.db_password
}

module "efs" {
  source = "terraform-aws-modules/efs/aws"
  name = var.name
  creation_token = var.name
  encrypted = false # because demo
  mount_targets = { for k, v in zipmap(local.azs, module.vpc.private_subnets) : k => { subnet_id = v } }
  security_group_vpc_id = module.vpc.vpc_id
  security_group_rules = {
    vpc = {
      cidr_blocks = module.vpc.private_subnets_cidr_blocks
    }
  }
  access_points = {
    themes = {
      posix_user = {
        gid = 33
        uid = 33
      }
      root_directory = {
        path = "/themes"
        creation_info = {
          owner_gid   = 33
          owner_uid   = 33
          permissions = 755
        }
      }
    }
    plugins = {
      posix_user = {
        gid = 33
        uid = 33
      }
      root_directory = {
        path = "/plugins"
        creation_info = {
          owner_gid   = 33
          owner_uid   = 33
          permissions = 755
        }
      }
    }
  }
}

module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws//modules/cluster"
  cluster_name = var.name
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 50
      }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
        weight = 50
      }
    }
  }
}

module "ecs_service" {
  source = "terraform-aws-modules/ecs/aws//modules/service"
  name = var.name
  cluster_arn = module.ecs_cluster.arn
  cpu = 512
  memory = 1024
  container_definitions = {
    (local.container_name) = {
      cpu       = 512
      memory    = 1024
      essential = true
      image     = "wordpress:latest"
      port_mappings = [
        {
          name          = local.container_name
          containerPort = local.container_port
          hostPort      = local.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name = "ALLOW_EMPTY_PASSWORD",
          value = "yes"
        },
        {
          name = "WORDPRESS_DATABASE_HOST",
          value = module.rds.db_instance_endpoint
        },
        {
          name = "WORDPRESS_DATABASE_USER",
          value = local.db_user
        },
        {
          name = "WORDPRESS_DATABASE_PASSWORD",
          value = local.db_password
        }
      ]
    }
  }
  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["ecs"].arn
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }
  subnet_ids = module.vpc.private_subnets
  security_group_rules = {
    alb_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      source_security_group_id = module.alb.security_group_id
    }
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  name = var.name
  load_balancer_type = "application"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets
  enable_deletion_protection = false # because demo
  security_group_ingress_rules = {
    all_http = {
      from_port   = local.container_port
      to_port     = local.container_port
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }
  listeners = {
    ex_http = {
      port = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "ecs"
      }
    }
  }
  target_groups = {
    ecs = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true
      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }
      # There's nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
  }
}
