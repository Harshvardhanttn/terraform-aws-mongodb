provider "aws" {
  region = var.region
}

#############################
# Fetch VPC CIDR
#############################
data "aws_vpc" "mongodb_vpc" {
  id = var.vpc_id
}

#############################
# Key Pair
#############################
resource "tls_private_key" "ssh_private_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
resource "aws_key_pair" "ssh_key" {
  key_name   = var.key_name
  public_key = tls_private_key.ssh_private_key.public_key_openssh
  provisioner "local-exec" { # This will create "mongodb.pem" where the terraform will run!!
    command = "rm -f ./mongodb.pem && echo '${tls_private_key.ssh_private_key.private_key_pem}' > ./mongodb.pem && chmod 400 mongodb.pem"
  }
}

#############################
# Password Generation
#############################
resource "random_string" "autogenerated_password" {
  length  = 16
  special = false
}

#############################
# Creating SSM Parameters
#############################
resource "aws_ssm_parameter" "mongodb_admin_password" {
  name  = "/${var.environment}/${var.ssm_parameter_prefix}/MONGODB_ADMIN_PASSWORD"
  type  = "SecureString"
  value = random_string.autogenerated_password.result
}
resource "aws_ssm_parameter" "mongodb_admin_user" {
  name  = "/${var.environment}/${var.ssm_parameter_prefix}/ADMIN_USER"
  type  = "String"
  value = var.mongo_username
}
resource "aws_ssm_parameter" "mongodb_admin_db" {
  name  = "/${var.environment}/${var.ssm_parameter_prefix}/ADMIN_DB"
  type  = "String"
  value = var.mongo_database
}

#############################
# Creating Data volumes 
#############################

resource "aws_ebs_volume" "master_data_volume" {
  depends_on = [ aws_instance.mongo_primary ]
  
  availability_zone = aws_instance.mongo_primary.availability_zone
  size              = var.volume_size
  type              = var.volume_type

  tags = {
    Project     = "${var.project_name}"
    Environment = "${var.environment}"
    Name        = "Mongo_Primary-disk"
    Type        = "primary"
  }
}

resource "aws_ebs_volume" "secondary_data_volume" {
  depends_on        = [ aws_instance.mongo_secondary ]
  count             = var.num_secondary_nodes

  availability_zone = aws_instance.mongo_secondary[count.index].availability_zone
  size              = var.volume_size
  type              = var.volume_type
  tags = {
    Project     = "${var.project_name}"
    Environment = "${var.environment}"
    Name        = "Mongo_Secondary_${count.index + 1}-disk"
    Type        = "secondary"
  }
}

#############################
# Attach volume to instance
#############################

resource "aws_volume_attachment" "master" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.master_data_volume.id
  instance_id = aws_instance.mongo_primary.id
}

resource "aws_volume_attachment" "secondary" {
  count       = var.num_secondary_nodes
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.secondary_data_volume[count.index].id
  instance_id = aws_instance.mongo_secondary[count.index].id
}


#############################
# Mongo Userdata
#############################
data "template_file" "userdata" {
  template = file("${path.module}/mongodb_userdata.sh")
  vars = {
    replica_set_name     = var.replica_set_name
    mongo_password       = random_string.autogenerated_password.result
    mongo_username       = var.mongo_username
    mongo_database       = var.mongo_database
    domain_name          = var.domain_name
    custom_domain        = var.custom_domain
    aws_region           = var.region
    environment          = var.environment
    ssm_parameter_prefix = var.ssm_parameter_prefix
    project_name         = var.project_name
    extended_user_data = file(var.extended_user_data_path == "" ? "" : var.extended_user_data_path)
  }
}

#############################
# Mongo Slave Instances
#############################
resource "aws_instance" "mongo_secondary" {
  count                       = var.num_secondary_nodes
  ami                         = var.mongo_ami
  instance_type               = var.secondary_node_type
  key_name                    = var.key_name
  subnet_id                   = var.mongo_subnet_id
  user_data                   = data.template_file.userdata.rendered
  vpc_security_group_ids      = ["${aws_security_group.mongo_sg.id}"]
  iam_instance_profile        = aws_iam_instance_profile.mongo-instance-profile.name
  associate_public_ip_address = false
  root_block_device {
    volume_type = var.volume_type
  }
  tags = {
    Project     = "${var.project_name}"
    Environment = "${var.environment}"
    Name        = "Mongo_Secondary_${count.index + 1}"
    Type        = "secondary"
  }
  provisioner "file" {
    source      = "${path.module}/populate_hosts_file.py"
    destination = "/home/ubuntu/populate_hosts_file.py"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = self.private_ip
      agent       = false
      private_key = tls_private_key.ssh_private_key.private_key_pem
    }
  }
  provisioner "file" {
    source      = "${path.module}/parse_instance_tags.py"
    destination = "/home/ubuntu/parse_instance_tags.py"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = self.private_ip
      agent       = false
      private_key = tls_private_key.ssh_private_key.private_key_pem
    }
  }
  provisioner "file" {
    source      = "${path.module}/keyFile"
    destination = "/home/ubuntu/keyFile"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = self.private_ip
      agent       = false
      private_key = tls_private_key.ssh_private_key.private_key_pem
    }
  }
  depends_on = [
    aws_key_pair.ssh_key
  ]
}

#############################
# Mongo Primary Instances
#############################
resource "aws_instance" "mongo_primary" {
  ami                         = var.mongo_ami
  instance_type               = var.primary_node_type
  key_name                    = var.key_name
  subnet_id                   = var.mongo_subnet_id
  user_data                   = data.template_file.userdata.rendered
  vpc_security_group_ids      = ["${aws_security_group.mongo_sg.id}"]
  iam_instance_profile        = aws_iam_instance_profile.mongo-instance-profile.name
  associate_public_ip_address = false
  root_block_device {
    volume_type = var.volume_type
  }
  tags = {
    Project     = "${var.project_name}"
    Environment = "${var.environment}"
    Name        = "Mongo_Primary"
    Type        = "primary"
  }
  provisioner "file" {
    source      = "${path.module}/populate_hosts_file.py"
    destination = "/home/ubuntu/populate_hosts_file.py"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = self.private_ip
      agent       = false
      private_key = tls_private_key.ssh_private_key.private_key_pem
    }
  }
  provisioner "file" {
    source      = "${path.module}/parse_instance_tags.py"
    destination = "/home/ubuntu/parse_instance_tags.py"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = self.private_ip
      agent       = false
      private_key = tls_private_key.ssh_private_key.private_key_pem
    }
  }
  provisioner "file" {
    source      = "${path.module}/keyFile"
    destination = "/home/ubuntu/keyFile"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = self.private_ip
      agent       = false
      private_key = tls_private_key.ssh_private_key.private_key_pem
    }
  }
  depends_on = [
    aws_key_pair.ssh_key
  ]
}
resource "aws_security_group" "mongo_sg" {
  name   = "MongoDB_SG"
  vpc_id = var.vpc_id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.mongodb_vpc.cidr_block}"]
  }
  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.mongodb_vpc.cidr_block}"]
  }
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["${data.aws_vpc.mongodb_vpc.cidr_block}"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "MongoDB_SG"
  }
}
data "aws_iam_policy_document" "instance-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "mongo-role" {
  name               = "${var.environment}-${var.region}-mongo_role"
  path               = "/system/"
  assume_role_policy = data.aws_iam_policy_document.instance-assume-role-policy.json
}
resource "aws_iam_instance_profile" "mongo-instance-profile" {
  name = "${var.environment}-${var.region}-mongo-instance-profile"
  role = aws_iam_role.mongo-role.name
}
resource "aws_iam_role_policy" "ec2-describe-instance-policy" {
  name   = "${var.environment}-${var.region}-ec2-describe-instance-policy"
  role   = aws_iam_role.mongo-role.id
  policy = <<EOF
{
      "Version": "2012-10-17",
      "Statement": [
          {
              "Effect": "Allow",
              "Action": [
                  "ec2:DescribeInstances",
                  "ec2:DescribeTags",
                  "ssm:PutParameter",
                  "ssm:GetParameter",
                  "ssm:GetParameters",
                  "ssm:DeleteParameter",
                  "ssm:GetParameterHistory",
                  "ssm:DeleteParameters",
                  "ssm:GetParametersByPath"
              ],
              "Resource": "*"
          }
      ]
}
EOF
}

data "aws_iam_policy" "mongo_ssm_mananged_instance_core" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "mongo_ssm_mananged_instance_core" {
  policy_arn = data.aws_iam_policy.mongo_ssm_mananged_instance_core.arn
  role       = aws_iam_role.mongo-role.id
}
